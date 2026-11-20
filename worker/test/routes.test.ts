import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker, { isAllowedPassthrough, requestWithinSizeLimit } from "../src/index";
import type { Env } from "../src/index";
import { chatAnswer, fakeFetch, makeEnv, sseJSON } from "./helpers";

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

describe("GET /health", () => {
  it("says it is up and has a model key, without any secret", async () => {
    const response = await call("/health", { env: { ZAI_API_KEY: "z" } });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, app: "dottie", hasModelKey: true });
  });

  it.each([["ANTHROPIC_API_KEY"], ["GROQ_API_KEY"], ["NVIDIA_API_KEY"]])("counts %s as a model key", async (keyName) => {
    expect(((await (await call("/health", { env: { [keyName]: "k" } })).json()) as any).hasModelKey).toBe(true);
  });

  it("says when no model key is set, and nothing about the other keys or the secret", async () => {
    const response = await call("/health", { env: { APP_SHARED_SECRET: "s", TELEGRAM_BOT_TOKEN: "t", JEV_API_KEY: "j" } });
    expect(await response.json()).toEqual({ ok: true, app: "dottie", hasModelKey: false });
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

  it("guards the Dots' route by API key header or ?key=", async () => {
    expect((await call("/gemini/v1beta/models", { env: secretEnv })).status).toBe(401);
    expect((await call("/gemini/v1beta/models?key=wrong", { env: secretEnv })).status).toBe(401);
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

  it("answers 500 with the error when a handler throws, on /chat and on the Dots' route", async () => {
    for (const path of ["/chat", "/gemini/v1beta/models/m:generateContent"]) {
      const brokenEnv = makeEnv();
      Object.defineProperty(brokenEnv, "ANTHROPIC_API_KEY", { get: () => { throw new Error("broken setting"); } });
      const request = new Request(`https://worker.test${path}`, { method: "POST", body: JSON.stringify({ contents: [] }) });
      const response = await worker.fetch(request, brokenEnv);
      expect(response.status).toBe(500);
      expect(await response.json()).toEqual({ error: "Something went wrong on Dottie's server." });
    }
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
      groq: "off",
      nimBackup: "off",
      claude: "off",
      glm: "off",
      jev: "off",
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

describe("POST /chat", () => {
  it("answers on Groq, without the model and provider fields, when no paid key is set", async () => {
    const calls = fakeFetch([["api.groq.com", chatAnswer({ content: "hello" })]]);
    const response = await call("/chat", { body: { model: "gemini-3.6-flash", provider: "groq", contents: [userText("hi")] }, env: { GROQ_API_KEY: "g" } });
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("text/event-stream");
    expect((await sseJSON(response)).candidates[0].content.parts[0].text).toBe("hello");
    expect(calls).toHaveLength(1);
    expect(calls[0].json.provider).toBeUndefined();
    expect(calls[0].json.model).not.toBe("gemini-3.6-flash");
  });

  it("answers 503 and never reaches Google when no model key is set", async () => {
    const calls = fakeFetch([]);
    const response = await call("/chat", { body: { contents: [userText("hi")] } });
    expect(response.status).toBe(503);
    expect(((await response.json()) as any).error).toContain("No model could answer");
    expect(calls).toHaveLength(0);
  });

  it("goes from Groq to NIM when Groq can't answer", async () => {
    const calls = fakeFetch([
      ["api.groq.com", new Response("busy", { status: 429 })],
      ["integrate.api.nvidia.com", chatAnswer({ content: "nim backup" })],
    ]);
    const response = await call("/chat", { body: { contents: [userText("hi")] }, env: { GROQ_API_KEY: "g", GROQ_TEXT_MODELS: "one", NVIDIA_API_KEY: "n", NIM_MODELS: "nim-one" } });
    expect((await sseJSON(response)).modelVersion).toBe("nim/nim-one");
    expect(calls.map((recorded) => new URL(recorded.url).host)).toEqual(["api.groq.com", "integrate.api.nvidia.com"]);
  });

  it("answers 503 when Groq and NIM both fail", async () => {
    fakeFetch([
      ["api.groq.com", new Response("down", { status: 500 })],
      ["integrate.api.nvidia.com", new Response("down", { status: 500 })],
    ]);
    const response = await call("/chat", { body: { contents: [userText("hi")] }, env: { GROQ_API_KEY: "g", GROQ_TEXT_MODELS: "one", NVIDIA_API_KEY: "n", NIM_MODELS: "one" } });
    expect(response.status).toBe(503);
  });

  it("skips a backup the request can't fit, or can't take at all", async () => {
    let calls = fakeFetch([["integrate.api.nvidia.com", chatAnswer({ content: "nim" })]]);
    const response = await call("/chat", { body: { contents: [userText("a".repeat(40_000))] }, env: { GROQ_API_KEY: "g", NVIDIA_API_KEY: "n" } });
    expect((await sseJSON(response)).candidates[0].content.parts[0].text).toBe("nim");
    expect(calls.every((recorded) => recorded.url.includes("nvidia.com"))).toBe(true);

    calls = fakeFetch([]);
    const audioBody = { contents: [{ role: "user", parts: [{ inlineData: { mimeType: "audio/wav", data: "AAAA" } }] }] };
    expect((await call("/chat", { body: audioBody, env: { GROQ_API_KEY: "g", NVIDIA_API_KEY: "n" } })).status).toBe(503);
    expect(calls).toHaveLength(0);
  });

  it("sends Groq a cut-down screen job", async () => {
    const longStep = "s".repeat(4000);
    const contents = [userText("task"), ...Array.from({ length: 12 }, (_, index) => ({ role: index % 2 === 0 ? "model" : "user", parts: [{ text: `${index}${longStep}` }] }))];
    const calls = fakeFetch([["api.groq.com", chatAnswer({ content: "ok" })]]);
    await call("/chat", { body: { contents }, env: { GROQ_API_KEY: "g", GROQ_TEXT_MODELS: "one" } });
    expect(calls[0].json.messages.length).toBeLessThan(13);
  });

  it("answers 400 when the body isn't a JSON object", async () => {
    expect((await call("/chat", { body: "[1,2]" })).status).toBe(400);
  });
});

describe("the Dots' Gemini-shaped route", () => {
  const generatePath = "/gemini/v1beta/models/agent-model:generateContent";

  it("lists one model, and describes any model it is asked about, without reaching Google", async () => {
    const calls = fakeFetch([]);
    const listing = (await (await call("/gemini/v1beta/models?pageSize=5")).json()) as any;
    expect(listing.models.map((model: any) => model.name)).toEqual(["models/gemini-3.6-flash"]);
    const single = (await (await call("/gemini/v1beta/models/agent-model")).json()) as any;
    expect(single.name).toBe("models/agent-model");
    expect(single.supportedGenerationMethods).toContain("generateContent");
    expect(calls).toHaveLength(0);
  });

  it("estimates countTokens here, from a plain body or a wrapped one", async () => {
    const calls = fakeFetch([]);
    const plain = (await (await call("/gemini/v1beta/models/agent-model:countTokens", { body: { contents: [userText("a".repeat(400))] } })).json()) as any;
    expect(plain.totalTokens).toBeGreaterThan(50);
    const wrapped = (await (await call("/gemini/v1beta/models/agent-model:countTokens", { body: { generateContentRequest: { contents: [userText("a".repeat(400))] } } })).json()) as any;
    expect(wrapped.totalTokens).toBe(plain.totalTokens);
    expect(calls).toHaveLength(0);
  });

  it("answers a Dot turn on Groq, streamed or not", async () => {
    let calls = fakeFetch([["api.groq.com", chatAnswer({ content: "groq" })]]);
    let response = await call(generatePath, { body: { contents: [userText("hi")] }, env: { GROQ_API_KEY: "g" } });
    expect(response.headers.get("content-type")).toBe("application/json");
    expect(((await response.json()) as any).candidates[0].content.parts[0].text).toBe("groq");
    expect(calls).toHaveLength(1);

    calls = fakeFetch([["api.groq.com", chatAnswer({ content: "groq stream" })]]);
    response = await call("/gemini/v1beta/models/agent-model:streamGenerateContent?alt=sse", { body: { contents: [userText("hi")] }, env: { GROQ_API_KEY: "g" } });
    expect(response.headers.get("content-type")).toBe("text/event-stream");
  });

  it("answers on NIM when Groq can't", async () => {
    fakeFetch([
      ["api.groq.com", new Response("down", { status: 500 })],
      ["integrate.api.nvidia.com", chatAnswer({ content: "nim" })],
    ]);
    const response = await call(generatePath, { body: { contents: [userText("hi")] }, env: { GROQ_API_KEY: "g", GROQ_TEXT_MODELS: "one", NVIDIA_API_KEY: "n" } });
    expect(((await response.json()) as any).candidates[0].content.parts[0].text).toBe("nim");
  });

  it("answers 503 in Gemini's error shape when no model answers", async () => {
    const calls = fakeFetch([]);
    const response = await call(generatePath, { body: { contents: [userText("hi")] } });
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: { code: 503, status: "UNAVAILABLE", message: "No model could answer right now. Try again in a moment." } });
    expect(calls).toHaveLength(0);
  });

  it("answers 400 when the body isn't JSON", async () => {
    const response = await call(generatePath, { body: "{not json", env: { GROQ_API_KEY: "g" } });
    expect(response.status).toBe(400);
  });
});

describe("what the Dots' route allows", () => {
  it.each([
    ["POST", "/v1beta/models/gemini-3.8-flash:generateContent"],
    ["POST", "/v1beta/models/gemini-3.8-flash:streamGenerateContent"],
    ["POST", "/v1beta/models/gemini-3.8-flash:countTokens"],
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
    ["POST", "/v1beta/models/embedding-model:embedContent"],
    ["POST", "/v1beta/models/embedding-model:batchEmbedContents"],
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

  it("answers 403 without calling anything", async () => {
    const calls = fakeFetch([]);
    const response = await call("/gemini/v1beta/files", { body: { file: {} } });
    expect(response.status).toBe(403);
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
    expect((await withLength("/chat", "2")).status).toBe(503);
    expect((await withLength("/chat", "lots")).status).toBe(503);
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
