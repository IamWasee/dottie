import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { isAllowedPassthrough, requestWithinSizeLimit } from "../src/index";
import type { Env } from "../src/index";
import { chatAnswer, fakeFetch, geminiTextAnswer, jsonAnswer, makeEnv, sseJSON } from "./helpers";

beforeEach(() => {
  vi.spyOn(console, "warn").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

function call(path: string, options: { method?: string; body?: unknown; headers?: Record<string, string>; env?: Partial<Env> } = {}) {
  const hasBody = options.body !== undefined;
  const request = new Request(`https://worker.test${path}`, {
    method: options.method ?? (hasBody ? "POST" : "GET"),
    headers: options.headers,
    body: hasBody ? (typeof options.body === "string" ? options.body : JSON.stringify(options.body)) : undefined,
  });
  return worker.fetch(request, makeEnv(options.env));
}

const userText = (text: string) => ({ role: "user", parts: [{ text }] });
const sseAnswer = (text: string) => new Response(`data: ${JSON.stringify({ candidates: [{ content: { parts: [{ text }] } }] })}\r\n\r\n`, { headers: { "content-type": "text/event-stream" } });

describe("GET /health", () => {
  it("says it is up and has a Gemini key, without any secret", async () => {
    const response = await call("/health");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, app: "dottie", hasGeminiKey: true });
  });

  it("says when the Gemini key is missing, and nothing about the other keys or the secret", async () => {
    const response = await call("/health", { env: { GROQ_API_KEY: "g", APP_SHARED_SECRET: "s", TELEGRAM_BOT_TOKEN: "t", GEMINI_API_KEY: "" } });
    expect(await response.json()).toEqual({ ok: true, app: "dottie", hasGeminiKey: false });
  });

  it("is open even when a shared secret is set", async () => {
    expect((await call("/health", { env: { APP_SHARED_SECRET: "s" } })).status).toBe(200);
  });
});

describe("the shared secret", () => {
  const secretEnv = { APP_SHARED_SECRET: "the-secret" };

  it("turns away a request without it", async () => {
    expect((await call("/config", { env: secretEnv })).status).toBe(401);
    expect((await call("/chat", { env: secretEnv, body: {} })).status).toBe(401);
  });

  it("turns away a wrong one", async () => {
    expect((await call("/config", { env: secretEnv, headers: { "x-clicky-secret": "wrong" } })).status).toBe(401);
  });

  it("takes it in x-clicky-secret or x-goog-api-key", async () => {
    expect((await call("/config", { env: secretEnv, headers: { "x-clicky-secret": "the-secret" } })).status).toBe(200);
    expect((await call("/config", { env: secretEnv, headers: { "x-goog-api-key": "the-secret" } })).status).toBe(200);
  });

  it("guards the Gemini passthrough by API key header or ?key=", async () => {
    fakeFetch([["generativelanguage.googleapis.com", geminiTextAnswer("ok")]]);
    expect((await call("/gemini/v1beta/models", { env: secretEnv })).status).toBe(401);
    expect((await call("/gemini/v1beta/models?key=wrong", { env: secretEnv })).status).toBe(401);
    expect((await call("/gemini-only/v1beta/models", { env: secretEnv })).status).toBe(401);
    expect((await call("/gemini/v1beta/models?key=the-secret", { env: secretEnv })).status).toBe(200);
    expect((await call("/gemini/v1beta/models", { env: secretEnv, headers: { "x-goog-api-key": "the-secret" } })).status).toBe(200);
  });
});

describe("routing", () => {
  it("answers 404 for an unknown path and 405 for a GET on a POST route", async () => {
    expect((await call("/nope", { body: {} })).status).toBe(404);
    expect((await call("/chat")).status).toBe(405);
    expect((await call("/nope")).status).toBe(405);
  });

  it("answers 500 with the error when a handler throws", async () => {
    vi.stubGlobal("fetch", () => Promise.reject(new Error("no network")));
    const response = await call("/live-token", { method: "POST" });
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "Something went wrong on Dottie's server." });
  });

  it("answers 404 on the Telegram webhook when there is no bot", async () => {
    expect((await call("/telegram/webhook", { body: {} })).status).toBe(404);
  });

  it("sends GET /search to the search handler", async () => {
    const response = await call("/search");
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "missing q" });
  });
});

describe("GET /config", () => {
  it("lists the model names, with Groq and NIM off", async () => {
    expect(await (await call("/config")).json()).toEqual({
      liveModel: "live-model",
      chatModel: "chat-model",
      higherModel: "higher-model",
      ttsModel: "tts-model",
      ttsVoice: "Kore",
      dictationModel: "dictation-model",
      groq: "off",
      nimBackup: "off",
      claude: "off",
      glm: "off",
    });
  });

  it("shows Groq's and NIM's models, or default", async () => {
    const withDefaults = (await (await call("/config", { env: { GROQ_API_KEY: "g", NVIDIA_API_KEY: "n" } })).json()) as any;
    expect(withDefaults.groq).toEqual({ textModels: "default", visionModels: "default" });
    expect(withDefaults.nimBackup).toBe("default");
    const withModels = (await (await call("/config", { env: { GROQ_API_KEY: "g", GROQ_TEXT_MODELS: "t", GROQ_VISION_MODELS: "v", NVIDIA_API_KEY: "n", NIM_MODELS: "m" } })).json()) as any;
    expect(withModels.groq).toEqual({ textModels: "t", visionModels: "v" });
    expect(withModels.nimBackup).toBe("m");
  });
});

describe("POST /live-token", () => {
  it("mints a single-use token that must start within two minutes", async () => {
    const calls = fakeFetch([["/auth_tokens", jsonAnswer({ name: "auth_tokens/abc" })]]);
    const before = Date.now();
    const response = await call("/live-token", { method: "POST" });
    expect(response.status).toBe(200);
    const answer = (await response.json()) as { token: string; model: string; expireTime: string };
    expect(answer.token).toBe("auth_tokens/abc");
    expect(answer.model).toBe("live-model");
    expect(calls[0].headers.get("x-goog-api-key")).toBe("test-gemini-key");
    expect(calls[0].json.uses).toBe(1);
    const startWindow = Date.parse(calls[0].json.newSessionExpireTime) - before;
    expect(startWindow).toBeGreaterThanOrEqual(119_000);
    expect(startWindow).toBeLessThanOrEqual(121_000);
    const lifetime = Date.parse(answer.expireTime) - before;
    expect(lifetime).toBeGreaterThanOrEqual(9 * 60 * 1000);
    expect(lifetime).toBeLessThanOrEqual(11 * 60 * 1000);
  });

  it("passes Gemini's error on", async () => {
    fakeFetch([["/auth_tokens", new Response('{"error":"bad key"}', { status: 403 })]]);
    const response = await call("/live-token", { method: "POST" });
    expect(response.status).toBe(403);
    expect(await response.text()).toBe('{"error":"bad key"}');
  });

  it("answers 502 when Gemini sends no token", async () => {
    fakeFetch([["/auth_tokens", jsonAnswer({})]]);
    const response = await call("/live-token", { method: "POST" });
    expect(response.status).toBe(502);
  });
});

describe("POST /chat", () => {
  it("streams Gemini's answer from the default model, without the model and provider fields", async () => {
    const calls = fakeFetch([["/models/chat-model:streamGenerateContent", sseAnswer("hello")]]);
    const response = await call("/chat", { body: { contents: [userText("hi")], provider: "anything" } });
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("text/event-stream");
    expect(response.headers.get("cache-control")).toBe("no-cache");
    expect((await sseJSON(response)).candidates[0].content.parts[0].text).toBe("hello");
    expect(calls[0].url).toContain("alt=sse");
    expect(calls[0].json).toEqual({ contents: [userText("hi")] });
  });

  it("uses the model the body names", async () => {
    const calls = fakeFetch([["/models/custom-model:", sseAnswer("ok")]]);
    await call("/chat", { body: { model: "custom-model", contents: [] } });
    expect(calls).toHaveLength(1);
  });

  it('maps "higher" to the higher model, or to the chat model when none is set', async () => {
    let calls = fakeFetch([["/models/higher-model:", sseAnswer("ok")]]);
    await call("/chat", { body: { model: "higher", contents: [] } });
    expect(calls).toHaveLength(1);
    calls = fakeFetch([["/models/chat-model:", sseAnswer("ok")]]);
    await call("/chat", { body: { model: "higher", contents: [] }, env: { GEMINI_HIGHER_MODEL: "" } });
    expect(calls).toHaveLength(1);
  });

  it.each(["not json", "[1,2]", ""])("answers 400 for the body %j", async (body) => {
    const response = await call("/chat", { method: "POST", body: body || undefined });
    expect(response.status).toBe(400);
  });

  it("moves to the next Gemini model when one is busy", async () => {
    const calls = fakeFetch([
      ["/models/chat-model:", new Response("busy", { status: 503 })],
      ["/models/backup-one:", sseAnswer("from backup")],
    ]);
    const response = await call("/chat", { body: { contents: [userText("hi")] } });
    expect((await sseJSON(response)).candidates[0].content.parts[0].text).toBe("from backup");
    expect(calls).toHaveLength(2);
  });

  it("passes on an error that isn't busy", async () => {
    fakeFetch([["/models/chat-model:", new Response('{"error":"bad request"}', { status: 400 })]]);
    const response = await call("/chat", { body: { contents: [] } });
    expect(response.status).toBe(400);
    expect(await response.text()).toBe('{"error":"bad request"}');
  });

  it("passes the busy answer on when every model is busy and there is no backup", async () => {
    fakeFetch([["generativelanguage.googleapis.com", new Response("all busy", { status: 429 })]]);
    const response = await call("/chat", { body: { contents: [userText("hi")] } });
    expect(response.status).toBe(429);
    expect(await response.text()).toBe("all busy");
  });

  it("asks Groq first when the body asks for it", async () => {
    const calls = fakeFetch([["api.groq.com", chatAnswer({ content: "quick" })]]);
    const response = await call("/chat", { body: { provider: "groq", contents: [userText("hi")] }, env: { GROQ_API_KEY: "g" } });
    expect((await sseJSON(response)).candidates[0].content.parts[0].text).toBe("quick");
    expect(calls).toHaveLength(1);
    expect(calls[0].json.provider).toBeUndefined();
  });

  it("goes to Gemini when Groq is asked for but has no key", async () => {
    const calls = fakeFetch([["/models/chat-model:", sseAnswer("gemini")]]);
    await call("/chat", { body: { provider: "groq", contents: [userText("hi")] } });
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toContain("generativelanguage");
  });

  it("goes to Gemini when Groq can't answer, and doesn't ask Groq again as a backup", async () => {
    const calls = fakeFetch([
      ["api.groq.com", new Response("down", { status: 503 })],
      ["generativelanguage.googleapis.com", new Response("busy", { status: 503 })],
    ]);
    const response = await call("/chat", { body: { provider: "groq", contents: [userText("hi")] }, env: { GROQ_API_KEY: "g", GROQ_TEXT_MODELS: "only-one" } });
    expect(response.status).toBe(503);
    expect(calls.filter((recorded) => recorded.url.includes("groq.com"))).toHaveLength(1);
    expect(calls.filter((recorded) => recorded.url.includes("generativelanguage"))).toHaveLength(3);
  });

  it("skips Groq for a request too big for it", async () => {
    const calls = fakeFetch([["/models/chat-model:", sseAnswer("gemini")]]);
    await call("/chat", { body: { provider: "groq", contents: [userText("a".repeat(40_000))] }, env: { GROQ_API_KEY: "g" } });
    expect(calls.every((recorded) => recorded.url.includes("generativelanguage"))).toBe(true);
  });

  it("sends Groq a cut-down screen job and Gemini the whole one", async () => {
    const longStep = "s".repeat(4000);
    const contents = [userText("task"), ...Array.from({ length: 12 }, (_, index) => ({ role: index % 2 === 0 ? "model" : "user", parts: [{ text: `${index}${longStep}` }] }))];
    const calls = fakeFetch([
      ["api.groq.com", new Response("down", { status: 500 })],
      ["/models/chat-model:", sseAnswer("gemini")],
    ]);
    await call("/chat", { body: { provider: "groq", contents }, env: { GROQ_API_KEY: "g", GROQ_TEXT_MODELS: "one" } });
    const groqCall = calls.find((recorded) => recorded.url.includes("groq.com"))!;
    const geminiCall = calls.find((recorded) => recorded.url.includes("generativelanguage"))!;
    expect(groqCall.json.messages.length).toBeLessThan(13);
    expect(geminiCall.json.contents).toHaveLength(13);
  });

  it("falls back to Groq, then NIM, when every Gemini model is busy", async () => {
    let calls = fakeFetch([
      ["generativelanguage.googleapis.com", new Response("busy", { status: 503 })],
      ["api.groq.com", chatAnswer({ content: "groq backup" })],
    ]);
    let response = await call("/chat", { body: { contents: [userText("hi")] }, env: { GROQ_API_KEY: "g", NVIDIA_API_KEY: "n" } });
    expect((await sseJSON(response)).candidates[0].content.parts[0].text).toBe("groq backup");
    expect(calls.some((recorded) => recorded.url.includes("nvidia.com"))).toBe(false);

    calls = fakeFetch([
      ["generativelanguage.googleapis.com", new Response("busy", { status: 503 })],
      ["api.groq.com", new Response("busy too", { status: 429 })],
      ["integrate.api.nvidia.com", chatAnswer({ content: "nim backup" })],
    ]);
    response = await call("/chat", { body: { contents: [userText("hi")] }, env: { GROQ_API_KEY: "g", NVIDIA_API_KEY: "n", NIM_MODELS: "nim-one" } });
    expect((await sseJSON(response)).modelVersion).toBe("nim/nim-one");
  });

  it("returns Gemini's busy answer when the backups fail too, or can't take the request", async () => {
    fakeFetch([
      ["generativelanguage.googleapis.com", new Response("busy", { status: 503 })],
      ["integrate.api.nvidia.com", new Response("down", { status: 500 })],
    ]);
    expect((await call("/chat", { body: { contents: [userText("hi")] }, env: { NVIDIA_API_KEY: "n" } })).status).toBe(503);

    const calls = fakeFetch([["generativelanguage.googleapis.com", new Response("busy", { status: 503 })]]);
    const audioBody = { contents: [{ role: "user", parts: [{ inlineData: { mimeType: "audio/wav", data: "AAAA" } }] }] };
    expect((await call("/chat", { body: audioBody, env: { GROQ_API_KEY: "g", NVIDIA_API_KEY: "n" } })).status).toBe(503);
    expect(calls.every((recorded) => recorded.url.includes("generativelanguage"))).toBe(true);
  });

  it("gives each model only the seconds the app allows before trying the next", async () => {
    const tried: string[] = [];
    vi.stubGlobal("fetch", (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input instanceof Request ? input.url : input);
      tried.push(url);
      if (url.includes("/models/chat-model:")) {
        return new Promise<Response>((_resolve, reject) => init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError"))));
      }
      return Promise.resolve(sseAnswer("backup was quick"));
    });
    const response = await call("/chat", { body: { contents: [userText("hi")] }, headers: { "x-dottie-attempt-seconds": "0.02" } });
    expect((await sseJSON(response)).candidates[0].content.parts[0].text).toBe("backup was quick");
    expect(tried).toHaveLength(2);
  });
});

describe("POST /tts", () => {
  it("returns the audio as raw bytes", async () => {
    const audioBytes = [0, 1, 2, 250, 255];
    const calls = fakeFetch([
      ["/models/tts-model:generateContent", jsonAnswer({ candidates: [{ content: { parts: [{ text: "note" }, { inlineData: { data: btoa(String.fromCharCode(...audioBytes)) } }] } }] })],
    ]);
    const response = await call("/tts", { body: { text: "hello there" } });
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("audio/L16; rate=24000; channels=1");
    expect([...new Uint8Array(await response.arrayBuffer())]).toEqual(audioBytes);
    expect(calls[0].json.contents[0].parts[0].text).toBe("hello there");
    expect(calls[0].json.generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName).toBe("Kore");
  });

  it.each([{}, { text: "" }, { text: 5 }, "not json"])("answers 400 for %j", async (body) => {
    const response = await call("/tts", { body });
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "missing text" });
  });

  it("turns away text far too long to speak, without asking Gemini", async () => {
    const calls = fakeFetch([]);
    const response = await call("/tts", { body: { text: "a".repeat(10_001) } });
    expect(response.status).toBe(413);
    expect(await response.json()).toEqual({ error: "That text is too long to speak." });
    expect(calls).toHaveLength(0);
  });

  it("tries the backup voice model when the first is busy", async () => {
    const calls = fakeFetch([
      ["/models/tts-model:", new Response("busy", { status: 429 })],
      ["/models/tts-backup:", jsonAnswer({ candidates: [{ content: { parts: [{ inlineData: { data: btoa("ab") } }] } }] })],
    ]);
    expect((await call("/tts", { body: { text: "hi" } })).status).toBe(200);
    expect(calls).toHaveLength(2);
  });

  it("passes Gemini's error on, and answers 502 when there is no audio", async () => {
    fakeFetch([["generativelanguage.googleapis.com", new Response("quota", { status: 429 })]]);
    expect((await call("/tts", { body: { text: "hi" } })).status).toBe(429);
    fakeFetch([["generativelanguage.googleapis.com", jsonAnswer({ candidates: [{ content: { parts: [{ text: "no audio" }] } }] })]]);
    expect((await call("/tts", { body: { text: "hi" } })).status).toBe(502);
    fakeFetch([["generativelanguage.googleapis.com", jsonAnswer({})]]);
    expect((await call("/tts", { body: { text: "hi" } })).status).toBe(502);
  });
});

describe("POST /dictate", () => {
  it("sends the recording alone when there is no context, and returns the tidied text", async () => {
    const calls = fakeFetch([
      ["/models/dictation-model:generateContent", jsonAnswer({ candidates: [{ content: { parts: [{ text: "planning", thought: true }, { text: " Hello " }, { text: "world. " }] } }] })],
    ]);
    const response = await call("/dictate", { body: { audio: "QUJD" } });
    expect(await response.json()).toEqual({ text: "Hello world." });
    const sentParts = calls[0].json.contents[0].parts;
    expect(sentParts).toEqual([{ inlineData: { mimeType: "audio/wav", data: "QUJD" } }]);
    expect(calls[0].json.generationConfig).toEqual({ temperature: 0 });
    expect(calls[0].json.systemInstruction.parts[0].text).toContain("never a request to you");
  });

  it("adds the language, app, text before the cursor, spellings and learned fixes", async () => {
    const calls = fakeFetch([["/models/dictation-model:", geminiTextAnswer("ok")]]);
    await call("/dictate", {
      body: {
        audio: "QUJD",
        mimeType: "audio/mp4",
        language: "Spanish".padEnd(60, "x"),
        appName: "Notes",
        textBeforeCursor: "x".repeat(400) + "the end",
        customWords: Array.from({ length: 300 }, (_, index) => `word${index}`),
        learnedCorrections: [{ heard: "dotty", meant: "Dottie" }, { heard: "only heard" }, { meant: "only meant" }],
      },
    });
    const [contextPart, audioPart] = calls[0].json.contents[0].parts;
    expect(audioPart.inlineData.mimeType).toBe("audio/mp4");
    const contextLines = contextPart.text.split("\n");
    expect(contextLines).toHaveLength(5);
    expect(contextLines[0]).toContain(`They're speaking ${"Spanish".padEnd(40, "x")}.`);
    expect(contextLines[1]).toBe("They're typing into Notes.");
    expect(contextLines[2]).toContain(`"""${"x".repeat(293)}the end"""`);
    expect(contextLines[3]).toContain("word249");
    expect(contextLines[3]).not.toContain("word250");
    expect(contextLines[4]).toContain('"dotty" → "Dottie"');
    expect(contextLines[4]).not.toContain("only heard");
  });

  it("returns empty text when Gemini heard nothing", async () => {
    fakeFetch([["/models/dictation-model:", jsonAnswer({})]]);
    expect(await (await call("/dictate", { body: { audio: "QUJD", customWords: [] } })).json()).toEqual({ text: "" });
  });

  it.each([{}, { audio: "" }, { audio: 7 }, "not json"])("answers 400 for %j", async (body) => {
    const response = await call("/dictate", { body });
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "missing audio" });
  });

  it("falls back to the chat backups when busy, and passes other errors on", async () => {
    const calls = fakeFetch([
      ["/models/dictation-model:", new Response("busy", { status: 503 })],
      ["/models/backup-one:", geminiTextAnswer("from backup")],
    ]);
    expect(await (await call("/dictate", { body: { audio: "QUJD" } })).json()).toEqual({ text: "from backup" });
    expect(calls).toHaveLength(2);
    fakeFetch([["generativelanguage.googleapis.com", new Response("bad audio", { status: 400 })]]);
    expect((await call("/dictate", { body: { audio: "QUJD" } })).status).toBe(400);
  });
});

describe("the Gemini passthrough", () => {
  const generatePath = "/gemini/v1beta/models/agent-model:generateContent";

  it("forwards the path, query and body with the real key, and drops the caller's key", async () => {
    const calls = fakeFetch([["generativelanguage.googleapis.com", new Response('{"models":[]}', { headers: { "content-type": "application/json; charset=UTF-8" } })]]);
    const response = await call("/gemini/v1beta/models?pageSize=5&key=caller-key", { headers: { "x-goog-api-key": "caller-key" } });
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/json; charset=UTF-8");
    expect(calls[0].url).toBe("https://generativelanguage.googleapis.com/v1beta/models?pageSize=5");
    expect(calls[0].headers.get("x-goog-api-key")).toBe("test-gemini-key");
    expect(calls[0].method).toBe("GET");
  });

  it("sends a POST body through untouched", async () => {
    const calls = fakeFetch([["generativelanguage.googleapis.com", new Response(new TextEncoder().encode("counted"))]]);
    const response = await call("/gemini/v1beta/models/agent-model:countTokens", { body: '{"contents":[ ]}', headers: { "content-type": "application/json" } });
    expect(await response.text()).toBe("counted");
    expect(response.headers.get("content-type")).toBeNull();
    expect(calls[0].bodyText).toBe('{"contents":[ ]}');
    expect(calls[0].headers.get("content-type")).toBe("application/json");
  });

  it("moves a busy model call on to the backups, and returns the last answer when all are busy", async () => {
    let calls = fakeFetch([
      ["/models/agent-model:", new Response("busy", { status: 503 })],
      ["/models/backup-one:", geminiTextAnswer("from backup")],
    ]);
    let response = await call(generatePath, { body: { contents: [userText("hi")] } });
    expect(response.status).toBe(200);
    expect(calls.map((recorded) => recorded.url)).toEqual([expect.stringContaining("agent-model:generateContent"), expect.stringContaining("backup-one:generateContent")]);

    calls = fakeFetch([["generativelanguage.googleapis.com", new Response("busy", { status: 429 })]]);
    response = await call(generatePath, { body: { contents: [userText("hi")] } });
    expect(response.status).toBe(429);
    expect(calls).toHaveLength(3);
  });

  it("doesn't try backups for a GET or for an error that isn't busy", async () => {
    let calls = fakeFetch([["generativelanguage.googleapis.com", new Response("busy", { status: 503 })]]);
    expect((await call("/gemini/v1beta/models/agent-model")).status).toBe(503);
    expect(calls).toHaveLength(1);
    calls = fakeFetch([["generativelanguage.googleapis.com", new Response("bad", { status: 400 })]]);
    expect((await call(generatePath, { body: { contents: [] } })).status).toBe(400);
    expect(calls).toHaveLength(1);
  });

  it("answers a Dot turn on Groq first when it fits, streamed or not", async () => {
    let calls = fakeFetch([["api.groq.com", chatAnswer({ content: "groq" })]]);
    let response = await call(generatePath, { body: { contents: [userText("hi")] }, env: { GROQ_API_KEY: "g" } });
    expect(response.headers.get("content-type")).toBe("application/json");
    expect(((await response.json()) as any).candidates[0].content.parts[0].text).toBe("groq");
    expect(calls).toHaveLength(1);

    calls = fakeFetch([["api.groq.com", chatAnswer({ content: "groq stream" })]]);
    response = await call("/gemini/v1beta/models/agent-model:streamGenerateContent?alt=sse", { body: { contents: [userText("hi")] }, env: { GROQ_API_KEY: "g" } });
    expect(response.headers.get("content-type")).toBe("text/event-stream");
  });

  it("goes to Gemini when the turn is too big for Groq, Groq fails, or the body isn't JSON", async () => {
    let calls = fakeFetch([["generativelanguage.googleapis.com", geminiTextAnswer("gemini")]]);
    await call(generatePath, { body: { contents: [userText("a".repeat(40_000))] }, env: { GROQ_API_KEY: "g" } });
    expect(calls.every((recorded) => recorded.url.includes("generativelanguage"))).toBe(true);

    calls = fakeFetch([
      ["api.groq.com", new Response("down", { status: 500 })],
      ["generativelanguage.googleapis.com", geminiTextAnswer("gemini")],
    ]);
    const response = await call(generatePath, { body: { contents: [userText("hi")] }, env: { GROQ_API_KEY: "g", GROQ_TEXT_MODELS: "one" } });
    expect(((await response.json()) as any).candidates[0].content.parts[0].text).toBe("gemini");

    calls = fakeFetch([["generativelanguage.googleapis.com", new Response("bad json", { status: 400 })]]);
    expect((await call(generatePath, { body: "{not json", env: { GROQ_API_KEY: "g" } })).status).toBe(400);
  });

  it("never asks Groq on /gemini-only, or for calls that aren't generateContent", async () => {
    let calls = fakeFetch([["generativelanguage.googleapis.com", geminiTextAnswer("gemini")]]);
    await call("/gemini-only/v1beta/models/agent-model:generateContent", { body: { contents: [userText("hi")] }, env: { GROQ_API_KEY: "g" } });
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("https://generativelanguage.googleapis.com/v1beta/models/agent-model:generateContent");

    calls = fakeFetch([["generativelanguage.googleapis.com", new Response("{}")]]);
    await call("/gemini/v1beta/models/agent-model:countTokens", { body: { contents: [userText("hi")] }, env: { GROQ_API_KEY: "g" } });
    expect(calls.every((recorded) => recorded.url.includes("generativelanguage"))).toBe(true);
  });

  it("answers on NIM when every Gemini model is busy", async () => {
    fakeFetch([
      ["generativelanguage.googleapis.com", new Response("busy", { status: 503 })],
      ["integrate.api.nvidia.com", chatAnswer({ content: "nim" })],
    ]);
    const response = await call(generatePath, { body: { contents: [userText("hi")] }, env: { NVIDIA_API_KEY: "n" } });
    expect(response.status).toBe(200);
    expect(((await response.json()) as any).candidates[0].content.parts[0].text).toBe("nim");
  });

  it("returns Gemini's busy answer when NIM fails, can't take the turn, or the body isn't JSON", async () => {
    fakeFetch([
      ["generativelanguage.googleapis.com", new Response("busy", { status: 503 })],
      ["integrate.api.nvidia.com", new Response("down", { status: 500 })],
    ]);
    expect((await call(generatePath, { body: { contents: [userText("hi")] }, env: { NVIDIA_API_KEY: "n" } })).status).toBe(503);

    let calls = fakeFetch([["generativelanguage.googleapis.com", new Response("busy", { status: 503 })]]);
    const audioTurn = { contents: [{ role: "user", parts: [{ inlineData: { mimeType: "audio/wav", data: "AAAA" } }] }] };
    expect((await call(generatePath, { body: audioTurn, env: { NVIDIA_API_KEY: "n" } })).status).toBe(503);
    expect(calls.every((recorded) => recorded.url.includes("generativelanguage"))).toBe(true);

    calls = fakeFetch([["generativelanguage.googleapis.com", new Response("busy", { status: 503 })]]);
    expect((await call(generatePath, { body: "{not json", env: { NVIDIA_API_KEY: "n" } })).status).toBe(503);
  });

  it("answers 500 when Gemini can't be reached", async () => {
    vi.stubGlobal("fetch", () => Promise.reject(new Error("no network")));
    const response = await call(generatePath, { body: { contents: [] } });
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "Something went wrong on Dottie's server." });
  });
});

describe("what the Gemini passthrough allows", () => {
  it.each([
    ["POST", "/v1beta/models/gemini-3.8-flash:generateContent"],
    ["POST", "/v1beta/models/gemini-3.8-flash:streamGenerateContent"],
    ["POST", "/v1beta/models/gemini-3.8-flash:countTokens"],
    ["POST", "/v1beta/models/embedding-model:embedContent"],
    ["POST", "/v1beta/models/embedding-model:batchEmbedContents"],
    ["POST", "/v1/models/m:generateContent"],
    ["POST", "/v1alpha/models/m:generateContent"],
    ["GET", "/v1beta/models"],
    ["GET", "/v1beta/models/gemini-3.8-flash"],
  ])("allows %s %s", (method, path) => {
    expect(isAllowedPassthrough(method, path)).toBe(true);
  });

  it.each([
    ["POST", "/v1beta/files"],
    ["POST", "/upload/v1beta/files"],
    ["GET", "/v1beta/files"],
    ["POST", "/v1beta/cachedContents"],
    ["POST", "/v1beta/tunedModels"],
    ["DELETE", "/v1beta/models/gemini-3.8-flash"],
    ["PATCH", "/v1beta/models/gemini-3.8-flash"],
    ["POST", "/v1beta/models/m:predictLongRunning"],
    ["POST", "/v1beta/models/m:generateContent/extra"],
    ["POST", "/v1beta/models/a/b:generateContent"],
    ["GET", "/v1beta/models/m:generateContent"],
    ["POST", "/v1beta/auth_tokens"],
    ["POST", "/v2/models/m:generateContent"],
    ["GET", "/"],
    ["GET", ""],
  ])("refuses %s %s", (method, path) => {
    expect(isAllowedPassthrough(method, path)).toBe(false);
  });

  it("answers 403 without calling Gemini", async () => {
    const calls = fakeFetch([]);
    const response = await call("/gemini/v1beta/files", { body: { file: {} } });
    expect(response.status).toBe(403);
    expect((await call("/gemini-only/v1beta/cachedContents", { body: {} })).status).toBe(403);
    expect((await call("/gemini/v1beta/models/m", { method: "DELETE" })).status).toBe(403);
    expect(calls).toHaveLength(0);
  });
});

describe("body size", () => {
  const withLength = (path: string, bytes: string) =>
    worker.fetch(new Request(`https://worker.test${path}`, { method: "POST", headers: { "content-length": bytes }, body: "{}" }), makeEnv());

  it("answers 413 for a body over 32 MB, before anything else", async () => {
    const calls = fakeFetch([]);
    const response = await withLength("/chat", String(33 * 1024 * 1024));
    expect(response.status).toBe(413);
    expect((await withLength("/gemini/v1beta/models/m:generateContent", String(33 * 1024 * 1024))).status).toBe(413);
    expect(calls).toHaveLength(0);
  });

  it("gives phone files room up to Telegram's 50 MB, and no more", async () => {
    expect((await withLength("/phone/telegram/sendDocument", String(40 * 1024 * 1024))).status).not.toBe(413);
    expect((await withLength("/phone/telegram/sendDocument", String(60 * 1024 * 1024))).status).toBe(413);
  });

  it("lets a normal body, and a length that isn't a number, through", async () => {
    fakeFetch([["generativelanguage.googleapis.com", sseAnswer("ok")]]);
    expect((await withLength("/chat", "2")).status).toBe(200);
    expect((await withLength("/chat", "lots")).status).toBe(200);
  });
});

describe("the rate limit", () => {
  const limiter = (success: boolean | Error) => {
    const keys: string[] = [];
    return {
      keys,
      binding: {
        limit: async ({ key }: { key: string }) => {
          keys.push(key);
          if (success instanceof Error) throw success;
          return { success };
        },
      } as unknown as RateLimit,
    };
  };

  it("answers 429 with retry-after once a caller is over it", async () => {
    const { binding, keys } = limiter(false);
    const request = new Request("https://worker.test/config", { headers: { "cf-connecting-ip": "203.0.113.9" } });
    const response = await worker.fetch(request, makeEnv({ REQUEST_RATE_LIMITER: binding }));
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(keys).toEqual(["203.0.113.9"]);
  });

  it("limits the Gemini passthrough too", async () => {
    const { binding } = limiter(false);
    const calls = fakeFetch([]);
    expect((await call("/gemini/v1beta/models", { env: { REQUEST_RATE_LIMITER: binding } })).status).toBe(429);
    expect(calls).toHaveLength(0);
  });

  it("lets a caller under the limit through, counted as unknown without an address", async () => {
    const { binding, keys } = limiter(true);
    expect((await call("/config", { env: { REQUEST_RATE_LIMITER: binding } })).status).toBe(200);
    expect(keys).toEqual(["unknown"]);
  });

  it("never counts /health, the Mac's long poll, or a caller without the secret", async () => {
    const { binding, keys } = limiter(false);
    expect((await call("/health", { env: { REQUEST_RATE_LIMITER: binding } })).status).toBe(200);
    expect((await call("/phone/telegram/getUpdates", { body: {}, env: { REQUEST_RATE_LIMITER: binding } })).status).not.toBe(429);
    expect((await call("/config", { env: { REQUEST_RATE_LIMITER: binding, APP_SHARED_SECRET: "s" } })).status).toBe(401);
    expect(keys).toEqual([]);
  });

  it("blocks nobody when the limiter itself fails", async () => {
    const { binding } = limiter(new Error("limiter is down"));
    expect((await call("/config", { env: { REQUEST_RATE_LIMITER: binding } })).status).toBe(200);
  });
});

describe("the size limit on a body", () => {
  const piecesOf = (pieces: string[]) =>
    new ReadableStream<Uint8Array>({
      start(controller) {
        for (const piece of pieces) controller.enqueue(new TextEncoder().encode(piece));
        controller.close();
      },
    });
  const streamedRequest = (pieces: string[]) =>
    new Request("https://worker.test/chat", { method: "POST", body: piecesOf(pieces), duplex: "half" } as RequestInit);

  it("lets a request without a body through as it is", async () => {
    const request = new Request("https://worker.test/config");
    expect(await requestWithinSizeLimit(request, 10)).toBe(request);
  });

  it("goes by the size a request declares", async () => {
    const small = new Request("https://worker.test/chat", { method: "POST", body: "12345", headers: { "content-length": "5" } });
    expect(await requestWithinSizeLimit(small, 10)).toBe(small);
    const big = new Request("https://worker.test/chat", { method: "POST", body: "12345", headers: { "content-length": "11" } });
    expect(await requestWithinSizeLimit(big, 10)).toBeUndefined();
  });

  it("keeps a body sent in pieces with no size when it fits", async () => {
    const request = streamedRequest(['{"a":', "1}"]);
    request.headers.delete("content-length");
    const checkedRequest = await requestWithinSizeLimit(request, 10);
    expect(checkedRequest?.method).toBe("POST");
    expect(await checkedRequest?.text()).toBe('{"a":1}');
  });

  it("drops a body sent in pieces with no size once it goes over", async () => {
    const request = streamedRequest(["123456", "789012"]);
    request.headers.delete("content-length");
    expect(await requestWithinSizeLimit(request, 10)).toBeUndefined();
  });

  it("answers 413 for a body that declares more than the route takes", async () => {
    const response = await call("/chat", { body: "{}", headers: { "content-length": String(33 * 1024 * 1024) } });
    expect(response.status).toBe(413);
  });
});
