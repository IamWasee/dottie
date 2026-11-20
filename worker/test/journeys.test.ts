import { env as workerBindings } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import type { Env } from "../src/index";
import { chatAnswer, fakeFetch, geminiTextAnswer, jsonAnswer, sseJSON } from "./helpers";

/**
 * Whole journeys, the way the app makes them: several requests in a row
 * against the Worker with the settings from wrangler.toml (the real model
 * names, backups, rate limiter and phone mailbox), and only the outside
 * services faked. The other test files check one route at a time; these
 * check that the routes still fit together.
 */
const BOT_TOKEN = "123456:journey-bot-token";

/** wrangler.toml's own settings and bindings, plus made-up keys. */
function deployedEnv(overrides: Partial<Env> = {}): Env {
  return { ...(workerBindings as unknown as Env), GEMINI_API_KEY: "test-gemini-key", ...overrides };
}

let nextCallerNumber = 0;

/** Each journey is its own caller, so one journey's requests never count against another's rate limit. */
function newCallerAddress(): string {
  nextCallerNumber += 1;
  return `198.51.100.${nextCallerNumber}`;
}

function appCaller(env: Env, callerAddress = newCallerAddress()) {
  return (path: string, options: { method?: string; body?: unknown; headers?: Record<string, string> } = {}) => {
    const hasBody = options.body !== undefined;
    const request = new Request(`https://worker.test${path}`, {
      method: options.method ?? (hasBody ? "POST" : "GET"),
      headers: { "cf-connecting-ip": callerAddress, ...options.headers },
      body: hasBody ? JSON.stringify(options.body) : undefined,
    });
    return worker.fetch(request, env);
  };
}

const userText = (text: string) => ({ role: "user", parts: [{ text }] });
const sseAnswer = (text: string) => new Response(`data: ${JSON.stringify({ candidates: [{ content: { parts: [{ text }] } }] })}\r\n\r\n`, { headers: { "content-type": "text/event-stream" } });
const busy = () => new Response("busy", { status: 503 });

beforeEach(() => {
  vi.spyOn(console, "warn").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("opening Dottie and asking out loud (live mode)", () => {
  it("checks the Worker, reads the model names and gets a token for the live model", async () => {
    const callWorker = appCaller(deployedEnv());
    const calls = fakeFetch([["/auth_tokens", jsonAnswer({ name: "auth_tokens/journey" })]]);

    expect(await (await callWorker("/health")).json()).toEqual({ ok: true, app: "dottie", hasGeminiKey: true });

    const configuration = (await (await callWorker("/config")).json()) as { liveModel: string; chatModel: string; ttsVoice: string };
    expect(configuration.liveModel).toBe("gemini-3.8-live");

    const token = (await (await callWorker("/live-token", { method: "POST" })).json()) as { token: string; model: string };
    expect(token).toMatchObject({ token: "auth_tokens/journey", model: configuration.liveModel });
    // Only the token request left the Worker, and it carried the real key.
    expect(calls).toHaveLength(1);
    expect(calls[0].headers.get("x-goog-api-key")).toBe("test-gemini-key");
  });
});

describe("a classic voice turn", () => {
  it("streams the answer, then speaks that same answer", async () => {
    const callWorker = appCaller(deployedEnv());
    const audioBytes = [1, 2, 3, 4];
    const calls = fakeFetch([
      ["gemini-3.8-flash:streamGenerateContent", sseAnswer("It's the blue button.")],
      ["gemini-3.8-flash-lite-tts:generateContent", jsonAnswer({ candidates: [{ content: { parts: [{ inlineData: { data: btoa(String.fromCharCode(...audioBytes)) } }] } }] })],
    ]);

    const chatResponse = await callWorker("/chat", { body: { contents: [userText("where do I click?")] } });
    const answerText = (await sseJSON(chatResponse)).candidates[0].content.parts[0].text as string;

    const speechResponse = await callWorker("/tts", { body: { text: answerText } });
    expect([...new Uint8Array(await speechResponse.arrayBuffer())]).toEqual(audioBytes);
    expect(calls[1].json.contents[0].parts[0].text).toBe("It's the blue button.");
    expect(calls[1].json.generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName).toBe("Kore");
  });

  it("still answers and speaks when the first chat model and the first voice model are busy", async () => {
    const callWorker = appCaller(deployedEnv());
    const calls = fakeFetch([
      ["gemini-3.8-flash:streamGenerateContent", busy()],
      ["gemini-3.6-flash:streamGenerateContent", sseAnswer("From the backup.")],
      ["gemini-3.8-flash-lite-tts:generateContent", busy()],
      ["gemini-3.8-flash-tts:generateContent", jsonAnswer({ candidates: [{ content: { parts: [{ inlineData: { data: btoa("pcm") } }] } }] })],
    ]);

    const chatResponse = await callWorker("/chat", { body: { contents: [userText("hi")] } });
    expect((await sseJSON(chatResponse)).candidates[0].content.parts[0].text).toBe("From the backup.");
    const speechResponse = await callWorker("/tts", { body: { text: "From the backup." } });
    expect(speechResponse.status).toBe(200);
    expect(new TextDecoder().decode(await speechResponse.arrayBuffer())).toBe("pcm");
    expect(calls).toHaveLength(4);
  });
});

describe("a quick ask that goes to Groq first", () => {
  it("answers from Groq in Gemini's shape, and from Gemini when Groq is down", async () => {
    const callWorker = appCaller(deployedEnv({ GROQ_API_KEY: "test-groq-key" }));
    let calls = fakeFetch([["api.groq.com", chatAnswer({ role: "assistant", content: "Paris." })]]);
    let response = await callWorker("/chat", { body: { provider: "groq", contents: [userText("capital of France?")] } });
    expect((await sseJSON(response)).candidates[0].content.parts[0].text).toBe("Paris.");
    expect(calls[0].json.model).toBe("openai/gpt-oss-120b");
    expect(calls[0].headers.get("authorization")).toBe("Bearer test-groq-key");

    calls = fakeFetch([
      ["api.groq.com", new Response("down", { status: 500 })],
      ["generativelanguage.googleapis.com", sseAnswer("Paris, from Gemini.")],
    ]);
    response = await callWorker("/chat", { body: { provider: "groq", contents: [userText("capital of France?")] } });
    expect((await sseJSON(response)).candidates[0].content.parts[0].text).toBe("Paris, from Gemini.");
    expect(calls.at(-1)?.url).toContain("generativelanguage.googleapis.com");
  });
});

describe("a screen job and a helper on the paid models", () => {
  it("sends screen steps to GLM, a helper's turn to Claude, and never asks Groq or Gemini", async () => {
    const callWorker = appCaller(deployedEnv({ ANTHROPIC_API_KEY: "test-claude-key", ZAI_API_KEY: "test-zai-key", GROQ_API_KEY: "test-groq-key" }));
    const calls = fakeFetch([
      ["api.z.ai", chatAnswer({ role: "assistant", content: null, tool_calls: [{ id: "c1", type: "function", function: { name: "click", arguments: '{"box_2d":[1,2,3,4]}' } }] })],
      ["api.anthropic.com", jsonAnswer({ content: [{ type: "text", text: "Site built." }], stop_reason: "end_turn", usage: { input_tokens: 3, output_tokens: 2 } })],
    ]);
    const screenStep = await callWorker("/chat", {
      body: {
        provider: "groq",
        contents: [{ role: "user", parts: [{ text: "open the first email" }, { inlineData: { mimeType: "image/png", data: "iVBORw0KGgo=" } }] }],
        tools: [{ functionDeclarations: [{ name: "click", parameters: { type: "OBJECT", properties: { box_2d: { type: "ARRAY", items: { type: "NUMBER" } } } } }] }],
      },
    });
    expect((await sseJSON(screenStep)).candidates[0].content.parts[0].functionCall).toMatchObject({ name: "click", args: { box_2d: [1, 2, 3, 4] } });

    const helperTurn = await callWorker("/gemini/v1beta/models/gemini-3.8-flash:generateContent", { body: { contents: [userText("build my site")] } });
    expect(((await helperTurn.json()) as any).candidates[0].content.parts[0].text).toBe("Site built.");

    expect(calls.map((recorded) => new URL(recorded.url).host)).toEqual(["api.z.ai", "api.anthropic.com"]);
    expect(calls[1].headers.get("x-api-key")).toBe("test-claude-key");
  });
});

describe("hold to dictate", () => {
  it("sends the recording with what the app knows and gets clean text back", async () => {
    const callWorker = appCaller(deployedEnv());
    const calls = fakeFetch([["gemini-3.5-flash-lite:generateContent", geminiTextAnswer(" Send it to Dottie. ")]]);
    const response = await callWorker("/dictate", { body: { audio: "QUJD", appName: "Notes", customWords: ["Dottie"] } });
    expect(await response.json()).toEqual({ text: "Send it to Dottie." });
    expect(JSON.stringify(calls[0].json)).toContain("Notes");
    expect(JSON.stringify(calls[0].json)).toContain("Dottie");
  });
});

describe("a helper's turn through Gemini CLI", () => {
  it("lists models, runs a turn with the real key, and is refused anything else", async () => {
    const callWorker = appCaller(deployedEnv());
    const calls = fakeFetch([
      [/\/v1beta\/models\?/, jsonAnswer({ models: [{ name: "models/gemini-3.8-flash" }] })],
      ["gemini-3.8-flash:generateContent", geminiTextAnswer("Done. The file is in output/.")],
    ]);
    const cliHeaders = { "x-goog-api-key": "whatever-the-cli-was-given" };

    const listResponse = await callWorker("/gemini/v1beta/models?pageSize=50", { headers: cliHeaders });
    expect(((await listResponse.json()) as { models: unknown[] }).models).toHaveLength(1);

    const turnResponse = await callWorker("/gemini/v1beta/models/gemini-3.8-flash:generateContent", { body: { contents: [userText("make the report")] }, headers: cliHeaders });
    expect(((await turnResponse.json()) as any).candidates[0].content.parts[0].text).toBe("Done. The file is in output/.");
    for (const call of calls) expect(call.headers.get("x-goog-api-key")).toBe("test-gemini-key");

    const callCountBefore = calls.length;
    const refused = await callWorker("/gemini/v1beta/files", { body: { file: "x" }, headers: cliHeaders });
    expect(refused.status).toBe(403);
    expect(calls).toHaveLength(callCountBefore);
  });

  it("moves a busy turn to the next model without the helper noticing", async () => {
    const callWorker = appCaller(deployedEnv());
    const calls = fakeFetch([
      ["gemini-3.8-flash:generateContent", busy()],
      ["gemini-3.6-flash:generateContent", geminiTextAnswer("From the backup.")],
    ]);
    const response = await callWorker("/gemini/v1beta/models/gemini-3.8-flash:generateContent", { body: { contents: [userText("hi")] } });
    expect(response.status).toBe(200);
    expect(calls).toHaveLength(2);
  });
});

describe("searching the web", () => {
  it("asks the engines, keeps the results that fit and reads the top page", async () => {
    const callWorker = appCaller(deployedEnv());
    const pageText = "The weather in London today is mild and cloudy with light rain later. ".repeat(6);
    fakeFetch([
      ["bing.com", new Response("<html><body></body></html>", { headers: { "content-type": "text/html" } })],
      [
        "html.duckduckgo.com",
        new Response(
          '<div class="result"><a rel="nofollow" class="result__a" href="https://weather.example/london">London weather today</a><a class="result__snippet" href="https://weather.example/london">Mild and cloudy in London</a></div>',
          { headers: { "content-type": "text/html" } }
        ),
      ],
      ["weather.example/london", new Response(`<p>${pageText}</p>`, { headers: { "content-type": "text/html" } })],
      ["wikipedia.org", jsonAnswer({ query: { search: [] } })],
    ]);
    const answer = (await (await callWorker("/search?q=weather%20in%20london%20today")).json()) as any;
    expect(answer.results[0].url).toBe("https://weather.example/london");
    expect(answer.topPage.text).toContain("mild and cloudy");
  });
});

describe("texting Dottie from a phone", () => {
  async function fromTelegram(env: Env, update: unknown) {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`dottie-webhook:${BOT_TOKEN}`));
    const webhookSecret = [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("").slice(0, 48);
    const request = new Request("https://worker.test/telegram/webhook", { method: "POST", headers: { "X-Telegram-Bot-Api-Secret-Token": webhookSecret }, body: JSON.stringify(update) });
    return worker.fetch(request, env);
  }
  const privateMessage = (chatID: number, text: string) => ({ update_id: 1, message: { text, chat: { id: chatID, type: "private" } } });
  const fakeTelegram = () =>
    fakeFetch([
      ["/getMe", jsonAnswer({ ok: true, result: { username: "dottie_journey_bot" } })],
      ["api.telegram.org", jsonAnswer({ ok: true, result: {} })],
    ]);

  it("pairs, gets a text on the Mac, answers only that phone, and stops after unpairing", async () => {
    const env = deployedEnv({ TELEGRAM_BOT_TOKEN: BOT_TOKEN });
    const callWorker = appCaller(env);
    const installKey = `journey-install-key-${crypto.randomUUID()}`;
    const macHeaders = { "x-dottie-phone-key": installKey };
    const chatID = 880_001;
    let telegramCalls = fakeTelegram();

    const pairing = (await (await callWorker("/phone/pair", { body: {}, headers: macHeaders })).json()) as { pairingCode: string; link?: string };
    expect(pairing.pairingCode).toBeTruthy();
    await fromTelegram(env, privateMessage(chatID, `/start ${pairing.pairingCode}`));
    await fromTelegram(env, privateMessage(chatID, "what's on my calendar?"));

    const updates = ((await (await callWorker("/phone/telegram/getUpdates", { body: { offset: 0 }, headers: macHeaders })).json()) as { result: any[] }).result;
    expect(updates.map((update) => update.message.text)).toEqual([`/start ${pairing.pairingCode}`, "what's on my calendar?"]);

    telegramCalls = fakeTelegram();
    const reply = await callWorker("/phone/telegram/sendMessage", { body: { chat_id: 12345, text: "Two meetings today." }, headers: macHeaders });
    expect(reply.status).toBe(200);
    expect(telegramCalls.find((call) => call.url.endsWith("/sendMessage"))?.json).toEqual({ chat_id: chatID, text: "Two meetings today." });

    // Another Mac can neither read this mailbox's pairing nor send to this phone.
    const strangerHeaders = { "x-dottie-phone-key": `stranger-${crypto.randomUUID()}` };
    expect((await callWorker("/phone/telegram/sendMessage", { body: { chat_id: chatID, text: "hi" }, headers: strangerHeaders })).status).toBe(409);

    expect(await (await callWorker("/phone/unpair", { body: {}, headers: macHeaders })).json()).toEqual({ ok: true });
    expect((await callWorker("/phone/telegram/sendMessage", { body: { text: "still there?" }, headers: macHeaders })).status).toBe(409);
  });
});

describe("one caller asking far too often", () => {
  it("is let through 300 times in a minute and then told to wait, while another caller carries on", async () => {
    const env = deployedEnv();
    const busyCaller = appCaller(env);
    const otherCaller = appCaller(env);
    const statuses: number[] = [];
    for (let requestNumber = 0; requestNumber < 301; requestNumber += 1) statuses.push((await busyCaller("/config")).status);
    expect(statuses.slice(0, 300).every((status) => status === 200)).toBe(true);
    expect(statuses[300]).toBe(429);
    expect((await otherCaller("/config")).status).toBe(200);
  });
});
