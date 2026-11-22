import { env as workerBindings } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import type { Env } from "../src/index";
import { DEFAULT_DAILY_LIMITS, SPEND_DAYS_KEPT, dailyLimits, dayBefore, installSpendResponse, recordInstallSpend, spendInAnswer, splitPassthroughKey, usageArea, usageIdentity, usageRefusal } from "../src/usageLimits";
import { chatAnswer, fakeFetch, jsonAnswer, makeEnv } from "./helpers";

const usageBinding = (workerBindings as unknown as Env).INSTALL_USAGE;

/** A Worker with the real counters and small limits, so a test reaches them in a few requests. */
function limitedEnv(limits: string, overrides: Partial<Env> = {}): Env {
  return makeEnv({ GROQ_API_KEY: "test-groq-key", INSTALL_USAGE: usageBinding, INSTALL_DAILY_LIMITS: limits, ...overrides });
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
  // Every model answer comes from Groq: the Worker has no Gemini behind it.
  fakeFetch([["api.groq.com", chatAnswer({ content: "ok" })]]);
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
    const env = makeEnv({ GROQ_API_KEY: "test-groq-key", INSTALL_DAILY_LIMITS: "chat=0" });
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
    const env = makeEnv({ GROQ_API_KEY: "test-groq-key", INSTALL_USAGE: brokenBinding, INSTALL_DAILY_LIMITS: "chat=0" });
    expect((await speak(newInstallID(), env)).status).toBe(200);
  });
});

describe("a helper's calls through Gemini CLI", () => {
  const generatePath = "/gemini/v1beta/models/agent-model:generateContent";
  const turn = (apiKey: string, env: Env) => fromInstall(undefined, generatePath, { body: { contents: [] }, headers: { "x-goog-api-key": apiKey }, env });

  it("are let in by the secret with the install id after it, and counted against that install", async () => {
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

describe("what each install spends", () => {
  const usageLine = (usage: Record<string, unknown>) => `data: ${JSON.stringify({ candidates: [], dottieUsage: usage })}\r\n\r\n`;

  it("reads every answer's usage from server-sent events and JSON bodies", () => {
    const sse = usageLine({ inputTokens: 100, outputTokens: 20, estimatedDollars: 0.002 }) + usageLine({ inputTokens: 50, outputTokens: 5, estimatedDollars: null });
    expect(spendInAnswer(sse)).toEqual({ asks: 2, dollars: 0.002, unpricedAsks: 1, inputTokens: 150, outputTokens: 25 });
    expect(spendInAnswer(JSON.stringify({ dottieUsage: { inputTokens: 3, outputTokens: 4, estimatedDollars: 0.5 } }))).toEqual({
      asks: 1, dollars: 0.5, unpricedAsks: 0, inputTokens: 3, outputTokens: 4,
    });
  });

  it("finds nothing in an answer without usage, broken JSON or odd numbers", () => {
    expect(spendInAnswer("data: {not json}\r\n\r\n")).toBeUndefined();
    expect(spendInAnswer(JSON.stringify({ candidates: [] }))).toBeUndefined();
    expect(spendInAnswer("null")).toBeUndefined();
    expect(spendInAnswer(JSON.stringify({ dottieUsage: { inputTokens: -5, outputTokens: "lots", estimatedDollars: 0.1 } }))).toEqual({
      asks: 1, dollars: 0.1, unpricedAsks: 0, inputTokens: 0, outputTokens: 0,
    });
  });

  it("counts days back across months, and nothing for a non-date", () => {
    expect(dayBefore("2026-12-01", 1)).toBe("2026-11-30");
    expect(dayBefore("2026-11-22", SPEND_DAYS_KEPT - 1)).toBe("2026-10-23");
    expect(dayBefore("", 3)).toBe("");
  });

  it("adds a /chat answer's cost to the install's day and shows it at /usage", async () => {
    fakeFetch([["api.groq.com", chatAnswer({ content: "ok" })]]);
    const env = limitedEnv("chat=100");
    const installID = newInstallID();
    expect((await speak(installID, env)).status).toBe(200);
    expect((await speak(installID, env)).status).toBe(200);
    const usage = (await (await fromInstall(installID, "/usage", { env })).json()) as { days: Array<Record<string, unknown>> };
    expect(usage.days).toHaveLength(1);
    expect(usage.days[0]).toMatchObject({ day: new Date().toISOString().slice(0, 10), asks: 2, inputTokens: 10, outputTokens: 14 });
    // Another install sees only its own.
    const otherUsage = (await (await fromInstall(newInstallID(), "/usage", { env })).json()) as { days: unknown[] };
    expect(otherUsage.days).toEqual([]);
  });

  it("adds a helper's Gemini CLI call to its install too", async () => {
    fakeFetch([["api.groq.com", chatAnswer({ content: "ok" })]]);
    const env = limitedEnv("helpers=100");
    const installID = newInstallID();
    const helperCall = await worker.fetch(
      new Request("https://worker.test/gemini/v1beta/models/m:generateContent", {
        method: "POST",
        headers: { "x-goog-api-key": `secret:${installID}` },
        body: JSON.stringify({ contents: [{ role: "user", parts: [{ text: "hi" }] }] }),
      }),
      env
    );
    expect(helperCall.status).toBe(200);
    const usage = (await (await fromInstall(installID, "/usage", { env })).json()) as { days: Array<Record<string, unknown>> };
    expect(usage.days[0]).toMatchObject({ asks: 1 });
  });

  it("records after the answer goes back when the Worker has a context", async () => {
    fakeFetch([["api.groq.com", chatAnswer({ content: "ok" })]]);
    const env = limitedEnv("chat=100");
    const installID = newInstallID();
    const waited: Promise<unknown>[] = [];
    const context = { waitUntil: (promise: Promise<unknown>) => waited.push(promise), passThroughOnException: () => {} } as unknown as ExecutionContext;
    const answer = await worker.fetch(
      new Request("https://worker.test/chat", { method: "POST", headers: { "x-dottie-install": installID }, body: JSON.stringify({ contents: [] }) }),
      env,
      context
    );
    expect(answer.status).toBe(200);
    expect(waited).toHaveLength(1);
    await Promise.all(waited);
    const usage = (await (await fromInstall(installID, "/usage", { env })).json()) as { days: unknown[] };
    expect(usage.days).toHaveLength(1);
  });

  it("keeps the last month of spend across days and drops older days and counts", async () => {
    const counter = usageBinding!.get(usageBinding!.idFromName(`install:${newInstallID()}`));
    const post = (path: string, body: Record<string, unknown>) => counter.fetch(`https://install-usage${path}`, { method: "POST", body: JSON.stringify(body) });
    await post("/spend", { day: "2026-09-01", asks: 1, dollars: 0.01 });
    await post("/spend", { day: "2026-11-01", asks: 2, dollars: 0.02 });
    await post("/count", { area: "chat", limit: 1, newInstallLimit: 10, day: "2026-11-01" });
    expect(await (await post("/count", { area: "chat", limit: 1, newInstallLimit: 10, day: "2026-11-01" })).json()).toEqual({ allowed: false });
    await post("/spend", { day: "2026-11-22", asks: 1, dollars: 0.005, unpricedAsks: 1 });
    const days = ((await (await counter.fetch("https://install-usage/spend")).json()) as { days: Array<{ day: string }> }).days.map((entry) => entry.day);
    expect(days).toEqual(["2026-11-01", "2026-11-22"]);
    // A new day lets the install ask again.
    expect(await (await post("/count", { area: "chat", limit: 1, newInstallLimit: 10, day: "2026-11-22" })).json()).toEqual({ allowed: true });
  });

  it("does nothing without the counters, for a failed answer or one without usage", async () => {
    const request = new Request("https://worker.test/chat", { method: "POST" });
    const url = new URL(request.url);
    await expect(recordInstallSpend(new Response("x"), request, url, {})).resolves.toBeUndefined();
    await expect(recordInstallSpend(new Response("x", { status: 500 }), request, url, { INSTALL_USAGE: usageBinding })).resolves.toBeUndefined();
    await expect(recordInstallSpend(new Response("{}"), request, url, { INSTALL_USAGE: usageBinding })).resolves.toBeUndefined();
    expect(await (await installSpendResponse(request, url, {})).json()).toEqual({ days: [] });
  });

  it("only logs a counter that fails", async () => {
    const warnings = vi.spyOn(console, "warn").mockImplementation(() => {});
    const brokenBinding = { idFromName: () => { throw new Error("down"); }, get: () => undefined } as unknown as DurableObjectNamespace;
    const request = new Request("https://worker.test/chat", { method: "POST" });
    const url = new URL(request.url);
    await recordInstallSpend(new Response(JSON.stringify({ dottieUsage: { inputTokens: 1 } })), request, url, { INSTALL_USAGE: brokenBinding });
    const failed = await installSpendResponse(request, url, { INSTALL_USAGE: { idFromName: () => "id", get: () => ({ fetch: () => Promise.reject(new Error("down")) }) } as unknown as DurableObjectNamespace });
    expect(failed.status).toBe(503);
    expect(warnings.mock.calls.flat().join(" ")).toContain("couldn't");
  });
});
