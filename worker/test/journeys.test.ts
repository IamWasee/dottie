import { env as workerBindings } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import type { Env } from "../src/index";
import { chatAnswer, fakeFetch, jsonAnswer, sseJSON } from "./helpers";

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
  return { ...(workerBindings as unknown as Env), ...overrides };
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

beforeEach(() => {
  vi.spyOn(console, "warn").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("opening Dottie", () => {
  it("checks the Worker and reads the model names without calling out", async () => {
    const callWorker = appCaller(deployedEnv());
    const calls = fakeFetch([]);

    expect(await (await callWorker("/health")).json()).toEqual({ ok: true, app: "dottie", hasModelKey: false });
    const configuration = (await (await callWorker("/config")).json()) as Record<string, unknown>;
    expect(configuration.claude).toBe("off");
    expect(configuration.chatModel).toBeUndefined();
    expect(calls).toHaveLength(0);
  });

  it("no longer serves the old Gemini voice, speech and dictation routes", async () => {
    const callWorker = appCaller(deployedEnv());
    fakeFetch([]);
    for (const removedRoute of ["/live-token", "/tts", "/dictate"]) {
      expect((await callWorker(removedRoute, { body: {} })).status).toBe(404);
    }
  });
});

describe("a chat turn", () => {
  it("streams the answer from Claude, and from Groq when Claude is down, never from Google", async () => {
    const callWorker = appCaller(deployedEnv({ ANTHROPIC_API_KEY: "test-claude-key", GROQ_API_KEY: "test-groq-key" }));
    let calls = fakeFetch([["api.anthropic.com", jsonAnswer({ type: "message", role: "assistant", content: [{ type: "text", text: "It's the blue button." }], stop_reason: "end_turn", usage: { input_tokens: 5, output_tokens: 5 } })]]);
    let chatResponse = await callWorker("/chat", { body: { contents: [userText("where do I click?")] } });
    expect((await sseJSON(chatResponse)).candidates[0].content.parts[0].text).toBe("It's the blue button.");
    expect(calls).toHaveLength(1);

    calls = fakeFetch([
      ["api.anthropic.com", new Response("overloaded", { status: 529 })],
      ["api.groq.com", chatAnswer({ role: "assistant", content: "Paris." })],
    ]);
    chatResponse = await callWorker("/chat", { body: { provider: "groq", contents: [userText("capital of France?")] } });
    expect((await sseJSON(chatResponse)).candidates[0].content.parts[0].text).toBe("Paris.");
    expect(calls.some((recorded) => recorded.url.includes("googleapis"))).toBe(false);
    expect(calls.at(-1)?.headers.get("authorization")).toBe("Bearer test-groq-key");
  });

  it("says no model could answer when none has a key", async () => {
    const callWorker = appCaller(deployedEnv());
    const calls = fakeFetch([]);
    expect((await callWorker("/chat", { body: { contents: [userText("hi")] } })).status).toBe(503);
    expect(calls).toHaveLength(0);
  });
});

describe("a spoken request and its screen job, with usage", () => {
  it("says which model answered each ask and what it cost, with wrangler.toml's screen-step limit", async () => {
    const env = deployedEnv({ ANTHROPIC_API_KEY: "test-claude-key", ZAI_API_KEY: "test-zai-key", GROQ_API_KEY: "test-groq-key" });
    expect(env.SCREEN_STEP_ATTEMPT_SECONDS).toBe("8");
    const callWorker = appCaller(env);
    vi.spyOn(console, "log").mockImplementation(() => {});
    fakeFetch([
      ["api.groq.com", chatAnswer({ role: "assistant", content: "REQUEST" })],
      ["api.anthropic.com", jsonAnswer({ type: "message", role: "assistant", content: [{ type: "text", text: "on it" }], stop_reason: "end_turn", usage: { input_tokens: 2000, output_tokens: 20 } })],
      ["api.z.ai", chatAnswer({ role: "assistant", content: "click Notes" })],
    ]);

    const talk = await sseJSON(await callWorker("/chat", { body: { provider: "talk", contents: [userText("open notes")] } }));
    expect(talk.dottieUsage).toMatchObject({ provider: "groq", estimatedDollars: null });

    const request = await sseJSON(await callWorker("/chat", { body: { provider: "request", contents: [userText("open notes")] } }));
    expect(request.dottieUsage).toMatchObject({ provider: "claude", model: "claude-haiku-5-5", inputTokens: 2000, outputTokens: 20 });
    expect(request.dottieUsage.estimatedDollars).toBeGreaterThan(0);

    const screenStep = await sseJSON(await callWorker("/chat", {
      body: { provider: "screen", contents: [{ role: "user", parts: [{ inlineData: { mimeType: "image/png", data: "iVBORw0KGgo=" } }, { text: "next?" }] }] },
    }));
    expect(screenStep.dottieUsage).toMatchObject({ provider: "glm", model: "glm-5.3-flash" });
  });
});

describe("a screen job and a helper on the paid models", () => {
  it("sends screen steps and a helper's turn to GLM, and never asks Claude, Groq or Gemini", async () => {
    const callWorker = appCaller(deployedEnv({ ANTHROPIC_API_KEY: "test-claude-key", ZAI_API_KEY: "test-zai-key", GROQ_API_KEY: "test-groq-key" }));
    const calls = fakeFetch([
      ["api.z.ai", chatAnswer({ role: "assistant", content: null, tool_calls: [{ id: "c1", type: "function", function: { name: "click", arguments: '{"box_2d":[1,2,3,4]}' } }] })],
    ]);
    const screenStep = await callWorker("/chat", {
      body: {
        provider: "groq",
        contents: [{ role: "user", parts: [{ text: "open the first email" }, { inlineData: { mimeType: "image/png", data: "iVBORw0KGgo=" } }] }],
        tools: [{ functionDeclarations: [{ name: "click", parameters: { type: "OBJECT", properties: { box_2d: { type: "ARRAY", items: { type: "NUMBER" } } } } }] }],
      },
    });
    expect((await sseJSON(screenStep)).candidates[0].content.parts[0].functionCall).toMatchObject({ name: "click", args: { box_2d: [1, 2, 3, 4] } });

    const helperCalls = fakeFetch([["api.z.ai", chatAnswer({ content: "Site built." })]]);
    const helperTurn = await callWorker("/gemini/v1beta/models/gemini-3.8-flash:generateContent", { body: { contents: [userText("build my site")] } });
    expect(((await helperTurn.json()) as any).candidates[0].content.parts[0].text).toBe("Site built.");

    expect(calls.map((recorded) => new URL(recorded.url).host)).toEqual(["api.z.ai"]);
    expect(helperCalls.map((recorded) => new URL(recorded.url).host)).toEqual(["api.z.ai"]);
  });
});

describe("a helper's turn through Gemini CLI", () => {
  it("lists models and counts tokens here, runs a turn on GLM, and is refused anything else", async () => {
    const callWorker = appCaller(deployedEnv({ ZAI_API_KEY: "test-zai-key" }));
    const calls = fakeFetch([["api.z.ai", chatAnswer({ content: "Done. The file is in output/." })]]);
    const cliHeaders = { "x-goog-api-key": "whatever-the-cli-was-given" };

    const listResponse = await callWorker("/gemini/v1beta/models?pageSize=50", { headers: cliHeaders });
    expect(((await listResponse.json()) as { models: unknown[] }).models).toHaveLength(1);
    const countResponse = await callWorker("/gemini/v1beta/models/gemini-3.6-flash:countTokens", { body: { contents: [userText("make the report")] }, headers: cliHeaders });
    expect(((await countResponse.json()) as { totalTokens: number }).totalTokens).toBeGreaterThan(0);
    expect(calls).toHaveLength(0);

    const turnResponse = await callWorker("/gemini/v1beta/models/gemini-3.6-flash:generateContent", { body: { contents: [userText("make the report")] }, headers: cliHeaders });
    expect(((await turnResponse.json()) as any).candidates[0].content.parts[0].text).toBe("Done. The file is in output/.");
    expect(calls.map((recorded) => new URL(recorded.url).host)).toEqual(["api.z.ai"]);

    const refused = await callWorker("/gemini/v1beta/files", { body: { file: "x" }, headers: cliHeaders });
    expect(refused.status).toBe(403);
    expect(calls).toHaveLength(1);
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
    // The limiter counts in minute windows; when the test happens to cross
    // a window's end the count starts over once, so up to two windows of
    // answers can come before the first "wait".
    const statuses: number[] = [];
    for (let requestNumber = 0; requestNumber < 601 && !statuses.includes(429); requestNumber += 1) {
      statuses.push((await busyCaller("/config")).status);
    }
    const firstRefusal = statuses.indexOf(429);
    expect(firstRefusal).toBeGreaterThanOrEqual(300);
    expect(statuses.slice(0, firstRefusal).every((status) => status === 200)).toBe(true);
    expect((await otherCaller("/config")).status).toBe(200);
  });
});
