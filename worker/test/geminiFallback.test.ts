import { afterEach, describe, expect, it, vi } from "vitest";
import { attemptTimeoutMilliseconds, fetchGeminiWithFallback, modelsToTry } from "../src/geminiFallback";
import { fakeFetch, geminiTextAnswer } from "./helpers";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe("modelsToTry", () => {
  it("puts the chosen model first, then the fallbacks", () => {
    expect(modelsToTry("main", "one,two")).toEqual(["main", "one", "two"]);
  });

  it("leaves out repeats", () => {
    expect(modelsToTry("main", "one,main,one")).toEqual(["main", "one"]);
  });

  it("ignores spaces and empty entries", () => {
    expect(modelsToTry("main", " one , ,two,")).toEqual(["main", "one", "two"]);
  });

  it("is only the chosen model without fallbacks", () => {
    expect(modelsToTry("main")).toEqual(["main"]);
    expect(modelsToTry("main", "")).toEqual(["main"]);
  });
});

describe("attemptTimeoutMilliseconds", () => {
  const requestWith = (seconds?: string) =>
    new Request("https://worker.test/chat", { headers: seconds === undefined ? {} : { "x-dottie-attempt-seconds": seconds } });

  it("is undefined without the header", () => {
    expect(attemptTimeoutMilliseconds(requestWith())).toBeUndefined();
  });

  it("turns seconds into milliseconds", () => {
    expect(attemptTimeoutMilliseconds(requestWith("8"))).toBe(8000);
    expect(attemptTimeoutMilliseconds(requestWith("2.5"))).toBe(2500);
  });

  it("never waits longer than 60 seconds", () => {
    expect(attemptTimeoutMilliseconds(requestWith("600"))).toBe(60_000);
  });

  it.each(["0", "-3", "soon", "Infinity", "NaN"])("is undefined for %s", (seconds) => {
    expect(attemptTimeoutMilliseconds(requestWith(seconds))).toBeUndefined();
  });
});

describe("fetchGeminiWithFallback", () => {
  it("calls the first model with the key and the body", async () => {
    const calls = fakeFetch([["/models/main:generateContent", geminiTextAnswer("hi")]]);
    const response = await fetchGeminiWithFallback("the-key", ["main", "backup"], "generateContent", '{"contents":[]}');
    expect(response.status).toBe(200);
    expect(calls).toHaveLength(1);
    expect(calls[0].headers.get("x-goog-api-key")).toBe("the-key");
    expect(calls[0].bodyText).toBe('{"contents":[]}');
    expect(calls[0].method).toBe("POST");
  });

  it.each([429, 500, 503, 504])("moves on to the next model after a %i", async (busyStatus) => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const calls = fakeFetch([
      ["/models/main:", new Response("busy", { status: busyStatus })],
      ["/models/backup:", geminiTextAnswer("from backup")],
    ]);
    const response = await fetchGeminiWithFallback("key", ["main", "backup"], "generateContent", "{}");
    expect(response.status).toBe(200);
    expect(calls.map((call) => call.url)).toEqual([expect.stringContaining("/models/main:"), expect.stringContaining("/models/backup:")]);
  });

  it.each([400, 401, 403, 404])("returns a %i at once without trying the others", async (errorStatus) => {
    const calls = fakeFetch([["/models/main:", new Response("bad", { status: errorStatus })]]);
    const response = await fetchGeminiWithFallback("key", ["main", "backup"], "generateContent", "{}");
    expect(response.status).toBe(errorStatus);
    expect(calls).toHaveLength(1);
  });

  it("returns the last model's busy answer when every model is busy", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const calls = fakeFetch([
      ["/models/main:", new Response("busy", { status: 503 })],
      ["/models/backup:", new Response("over the limit", { status: 429 })],
    ]);
    const response = await fetchGeminiWithFallback("key", ["main", "backup"], "generateContent", "{}");
    expect(response.status).toBe(429);
    expect(await response.text()).toBe("over the limit");
    expect(calls).toHaveLength(2);
  });

  it("encodes a model name that has a slash", async () => {
    const calls = fakeFetch([["/models/", geminiTextAnswer("ok")]]);
    await fetchGeminiWithFallback("key", ["tuned/model"], "generateContent", "{}");
    expect(calls[0].url).toContain("/models/tuned%2Fmodel:generateContent");
  });

  it("gives up on a model that is slow to start and tries the next", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const calls: string[] = [];
    vi.stubGlobal("fetch", (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      calls.push(url);
      if (url.includes("/models/slow:")) {
        // Never answers; fails only when the attempt is called off.
        return new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
        });
      }
      return Promise.resolve(geminiTextAnswer("from the quick one"));
    });
    const response = await fetchGeminiWithFallback("key", ["slow", "quick"], "generateContent", "{}", 20);
    expect(response.status).toBe(200);
    expect(calls).toHaveLength(2);
  });

  it("doesn't time the last model, since nothing is left to try", async () => {
    let lastModelSignal: AbortSignal | null | undefined = null;
    vi.stubGlobal("fetch", (_input: RequestInfo | URL, init?: RequestInit) => {
      lastModelSignal = init?.signal;
      return Promise.resolve(geminiTextAnswer("ok"));
    });
    await fetchGeminiWithFallback("key", ["only"], "generateContent", "{}", 20);
    expect(lastModelSignal).toBeUndefined();
  });

  it("passes on an error that isn't a timeout", async () => {
    vi.stubGlobal("fetch", () => Promise.reject(new Error("network is down")));
    await expect(fetchGeminiWithFallback("key", ["main", "backup"], "generateContent", "{}", 20)).rejects.toThrow("network is down");
  });
});
