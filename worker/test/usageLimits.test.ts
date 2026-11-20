import { env as workerBindings } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import type { Env } from "../src/index";
import { DEFAULT_DAILY_LIMITS, dailyLimits, splitPassthroughKey, usageArea, usageIdentity, usageRefusal } from "../src/usageLimits";
import { fakeFetch, geminiTextAnswer, jsonAnswer, makeEnv } from "./helpers";

const usageBinding = (workerBindings as unknown as Env).INSTALL_USAGE;

/** A Worker with the real counters and small limits, so a test reaches them in a few requests. */
function limitedEnv(limits: string, overrides: Partial<Env> = {}): Env {
  return makeEnv({ INSTALL_USAGE: usageBinding, INSTALL_DAILY_LIMITS: limits, ...overrides });
}

/** A fresh install for each test, so tests never share a counter. */
const newInstallID = () => crypto.randomUUID();

function fromInstall(installID: string | undefined, path: string, options: { method?: string; body?: unknown; headers?: Record<string, string>; env: Env }) {
  const hasBody = options.body !== undefined;
  const headers: Record<string, string> = { ...options.headers };
  if (installID) headers["x-dottie-install"] = installID;
  const request = new Request(`https://worker.test${path}`, {
    method: options.method ?? (hasBody ? "POST" : "GET"),
    headers,
    body: hasBody ? JSON.stringify(options.body) : undefined,
  });
  return worker.fetch(request, options.env);
}

const speak = (installID: string | undefined, env: Env, headers?: Record<string, string>) => fromInstall(installID, "/chat", { body: { contents: [] }, env, headers });

beforeEach(() => {
  vi.spyOn(console, "warn").mockImplementation(() => {});
  fakeFetch([
    [":streamGenerateContent", new Response("data: {}\r\n\r\n", { headers: { "content-type": "text/event-stream" } })],
    [":generateContent", jsonAnswer({ candidates: [{ content: { parts: [{ text: "ok" }, { inlineData: { data: btoa("pcm") } }] } }] })],
    ["/auth_tokens", jsonAnswer({ name: "auth_tokens/abc" })],
  ]);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("usageArea", () => {
  it.each([
    ["POST", "/chat", "chat"],
    ["POST", "/jev", "chat"],
    ["GET", "/search", "search"],
    ["POST", "/gemini/v1beta/models/m:generateContent", "helpers"],
    ["POST", "/gemini-only/v1beta/models/m:generateContent", "helpers"],
  ])("counts %s %s as %s", (method, pathname, area) => {
    expect(usageArea(method, pathname)).toBe(area);
  });

  it.each([
    ["GET", "/health"],
    ["GET", "/config"],
    ["GET", "/gemini/v1beta/models"],
    ["POST", "/phone/pair"],
    ["POST", "/search"],
    ["GET", "/chat"],
  ])("doesn't count %s %s", (method, pathname) => {
    expect(usageArea(method, pathname)).toBeUndefined();
  });
});

describe("dailyLimits", () => {
  it("is the defaults when nothing is set", () => {
    expect(dailyLimits(undefined)).toEqual(DEFAULT_DAILY_LIMITS);
    expect(dailyLimits("")).toEqual(DEFAULT_DAILY_LIMITS);
  });

  it("takes the areas that are set and keeps the defaults for the rest", () => {
    const limits = dailyLimits(" voice = 5 ,chat=0,newInstalls=7");
    expect(limits.voice).toBe(5);
    expect(limits.chat).toBe(0);
    expect(limits.newInstalls).toBe(7);
    expect(limits.speech).toBe(DEFAULT_DAILY_LIMITS.speech);
  });

  it("ignores names it doesn't know and values that aren't whole numbers", () => {
    expect(dailyLimits("games=5,voice=lots,chat=-1,speech=1.5,dictation=,search")).toEqual(DEFAULT_DAILY_LIMITS);
  });
});

describe("splitPassthroughKey", () => {
  it("takes the install id off the end of the key", () => {
    const installID = newInstallID();
    expect(splitPassthroughKey(`the:secret:${installID}`)).toEqual({ secret: "the:secret", installID });
  });

  it("leaves a key without an install id whole", () => {
    expect(splitPassthroughKey("just-a-secret")).toEqual({ secret: "just-a-secret" });
    expect(splitPassthroughKey("secret:short")).toEqual({ secret: "secret:short" });
    expect(splitPassthroughKey("")).toEqual({ secret: "" });
  });
});

describe("usageIdentity", () => {
  const identityOf = (headers: Record<string, string>, path = "/chat") => usageIdentity(new Request(`https://worker.test${path}`, { headers }), new URL(`https://worker.test${path}`));

  it("is the install id from the header", () => {
    const installID = newInstallID();
    expect(identityOf({ "x-dottie-install": installID, "cf-connecting-ip": "203.0.113.1" })).toBe(`install:${installID}`);
  });

  it("is the install id from the end of Gemini CLI's key, in a header or the address", () => {
    const installID = newInstallID();
    expect(identityOf({ "x-goog-api-key": `secret:${installID}` })).toBe(`install:${installID}`);
    expect(identityOf({}, `/gemini/v1beta/models?key=secret:${installID}`)).toBe(`install:${installID}`);
  });

  it("is the caller's address when the install id is missing or not believable", () => {
    expect(identityOf({ "cf-connecting-ip": "203.0.113.1" })).toBe("address:203.0.113.1");
    expect(identityOf({ "x-dottie-install": "no spaces allowed here!", "cf-connecting-ip": "203.0.113.1" })).toBe("address:203.0.113.1");
    expect(identityOf({})).toBe("address:unknown");
  });
});

describe("an install's limit for the day", () => {
  it("lets the area's requests through, then answers 429 until the next day", async () => {
    const env = limitedEnv("chat=2");
    const installID = newInstallID();
    expect((await speak(installID, env)).status).toBe(200);
    expect((await speak(installID, env)).status).toBe(200);

    const refused = await speak(installID, env);
    expect(refused.status).toBe(429);
    expect(await refused.json()).toEqual({ error: "That's today's limit for questions and screen work. It starts over at midnight UTC.", limit: "chat" });
    const retryAfterSeconds = Number(refused.headers.get("retry-after"));
    expect(retryAfterSeconds).toBeGreaterThan(0);
    expect(retryAfterSeconds).toBeLessThanOrEqual(24 * 60 * 60);
  });

  it("doesn't ask the model once the limit is reached", async () => {
    const env = limitedEnv("chat=1");
    const installID = newInstallID();
    await speak(installID, env);
    const calls = fakeFetch([]);
    expect((await speak(installID, env)).status).toBe(429);
    expect(calls).toHaveLength(0);
  });

  it("counts each area and each install by itself", async () => {
    const env = limitedEnv("chat=1,helpers=1");
    const installID = newInstallID();
    expect((await speak(installID, env)).status).toBe(200);
    expect((await speak(installID, env)).status).toBe(429);
    expect((await fromInstall(installID, "/gemini/v1beta/models/m:generateContent", { body: { contents: [] }, env })).status).toBe(200);
    expect((await speak(newInstallID(), env)).status).toBe(200);
  });

  it("starts again the next day", async () => {
    const env = limitedEnv("chat=1");
    const installID = newInstallID();
    await speak(installID, env);
    expect((await speak(installID, env)).status).toBe(429);

    vi.useFakeTimers({ toFake: ["Date"], now: Date.now() + 24 * 60 * 60 * 1000 });
    try {
      expect((await speak(installID, env)).status).toBe(200);
      expect((await speak(installID, env)).status).toBe(429);
    } finally {
      vi.useRealTimers();
    }
  });

  it("never counts the routes that cost nothing", async () => {
    const env = limitedEnv("speech=0,voice=0,chat=0,dictation=0,helpers=0,search=0");
    const installID = newInstallID();
    expect((await fromInstall(installID, "/health", { env })).status).toBe(200);
    expect((await fromInstall(installID, "/config", { env })).status).toBe(200);
    fakeFetch([["generativelanguage.googleapis.com", jsonAnswer({ models: [] })]]);
    expect((await fromInstall(installID, "/gemini/v1beta/models", { env })).status).toBe(200);
  });

  it("counts a caller without an install id by its address", async () => {
    const env = limitedEnv("chat=1");
    const address = `203.0.113.${Math.floor(Math.random() * 200) + 1}`;
    expect((await speak(undefined, env, { "cf-connecting-ip": address })).status).toBe(200);
    expect((await speak(undefined, env, { "cf-connecting-ip": address })).status).toBe(429);
  });

  it("never limits an install on the unlimited list", async () => {
    const installID = newInstallID();
    const env = limitedEnv("chat=0", { UNLIMITED_INSTALL_IDS: ` other-install , ${installID} ` });
    expect((await speak(installID, env)).status).toBe(200);
    expect((await speak(newInstallID(), env)).status).toBe(429);
  });

  it("counts nothing without the counter binding", async () => {
    const env = makeEnv({ INSTALL_DAILY_LIMITS: "chat=0" });
    expect((await speak(newInstallID(), env)).status).toBe(200);
  });

  it("lets the request through when the counter breaks", async () => {
    const brokenBinding = {
      idFromName: () => "id",
      get: () => ({
        fetch: async () => {
          throw new Error("counter is down");
        },
      }),
    } as unknown as DurableObjectNamespace;
    const env = makeEnv({ INSTALL_USAGE: brokenBinding, INSTALL_DAILY_LIMITS: "chat=0" });
    expect((await speak(newInstallID(), env)).status).toBe(200);
  });
});

describe("a helper's calls through Gemini CLI", () => {
  const generatePath = "/gemini/v1beta/models/agent-model:generateContent";
  const turn = (apiKey: string, env: Env) => fromInstall(undefined, generatePath, { body: { contents: [] }, headers: { "x-goog-api-key": apiKey }, env });

  it("are let in by the secret with the install id after it, and counted against that install", async () => {
    fakeFetch([["generativelanguage.googleapis.com", geminiTextAnswer("done")]]);
    const env = limitedEnv("helpers=1", { APP_SHARED_SECRET: "the-secret" });
    const installID = newInstallID();
    expect((await turn(`the-secret:${installID}`, env)).status).toBe(200);
    expect((await turn(`the-secret:${installID}`, env)).status).toBe(429);
    expect((await turn(`the-secret:${newInstallID()}`, env)).status).toBe(200);
  });

  it("are turned away with the wrong secret, whatever install id follows it", async () => {
    const env = limitedEnv("helpers=5", { APP_SHARED_SECRET: "the-secret" });
    expect((await turn(`wrong-secret:${newInstallID()}`, env)).status).toBe(401);
    expect((await turn(newInstallID(), env)).status).toBe(401);
  });

  it("still take the bare secret from an older copy of the app", async () => {
    fakeFetch([["generativelanguage.googleapis.com", geminiTextAnswer("done")]]);
    const env = limitedEnv("helpers=5", { APP_SHARED_SECRET: "the-secret" });
    expect((await turn("the-secret", env)).status).toBe(200);
  });

  it("let the secret with an install id through on the other routes too", async () => {
    const env = limitedEnv("chat=5", { APP_SHARED_SECRET: "the-secret" });
    const response = await fromInstall(undefined, "/chat", { body: { contents: [] }, headers: { "x-goog-api-key": `the-secret:${newInstallID()}` }, env });
    expect(response.status).toBe(200);
  });
});

describe("new installs in a day", () => {
  it("are let in up to the day's number, and installs already known keep working", async () => {
    // Its own directory, so the other tests' installs don't count here.
    const directoryCounts = new Map<string, number>();
    const knownInstalls = new Set<string>();
    const smallWorld = {
      idFromName: (name: string) => name,
      get: (name: string) => ({
        fetch: async (_address: string, init: RequestInit) => {
          const body = JSON.parse(String(init.body)) as { newInstallLimit: number };
          if (!knownInstalls.has(name)) {
            const seenToday = directoryCounts.get("today") ?? 0;
            if (seenToday >= body.newInstallLimit) return jsonAnswer({ allowed: false, reason: "newInstalls" });
            directoryCounts.set("today", seenToday + 1);
            knownInstalls.add(name);
          }
          return jsonAnswer({ allowed: true });
        },
      }),
    } as unknown as DurableObjectNamespace;
    const settings = { INSTALL_USAGE: smallWorld, INSTALL_DAILY_LIMITS: "newInstalls=1" };
    const requestFrom = (installID: string) => new Request("https://worker.test/chat", { method: "POST", headers: { "x-dottie-install": installID } });
    const url = new URL("https://worker.test/chat");
    const firstInstall = newInstallID();

    expect(await usageRefusal(requestFrom(firstInstall), url, settings)).toBeUndefined();
    const refused = await usageRefusal(requestFrom(newInstallID()), url, settings);
    expect(refused?.status).toBe(429);
    expect(await refused?.json()).toEqual({ error: "Dottie isn't taking new installs today. Try again tomorrow.", limit: "newInstalls" });
    expect(await usageRefusal(requestFrom(firstInstall), url, settings)).toBeUndefined();
  });

  it("are counted by the real directory: a day with no room turns a new install away and takes it the next day", async () => {
    const env = limitedEnv("chat=5,newInstalls=0");
    const installID = newInstallID();
    const refused = await speak(installID, env);
    expect(refused.status).toBe(429);
    expect(((await refused.json()) as { limit: string }).limit).toBe("newInstalls");

    // With room again the same install is let in, and stays known after that.
    const roomyEnv = limitedEnv("chat=5,newInstalls=100000");
    expect((await speak(installID, roomyEnv)).status).toBe(200);
    expect((await speak(installID, env)).status).toBe(200);
  });
});
