import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { answerUsage, answerWithProvider, DEFAULT_MODEL_PRICES, groqProvider, modelPrices, zaiProvider } from "../src/chatCompletions";
import worker, { DEFAULT_SCREEN_STEP_ATTEMPT_SECONDS, DEFAULT_SCREEN_STEP_SCREENSHOTS, keepingNewestScreenshots, screenStepAttemptMilliseconds, screenStepScreenshotCount, withAttemptLimit } from "../src/index";
import type { Env } from "../src/index";
import { chatAnswer, fakeFetch, imagePart, jsonAnswer, makeEnv, pngBase64, sseJSON } from "./helpers";

/**
 * Two things round 2 of 1.0.80 showed: screen steps waited for GLM's whole
 * 45 s try while the app gave up at 20 s (so Claude, next in line, never
 * answered), and nothing said which model answered an ask or what it cost.
 */

beforeEach(() => {
  vi.spyOn(console, "warn").mockImplementation(() => {});
  vi.spyOn(console, "log").mockImplementation(() => {});
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

const userText = (text: string) => ({ role: "user", parts: [{ text }] });
const screenshotTurn = () => ({ role: "user", parts: [imagePart(pngBase64(1440, 900)), { text: "next step?" }] });

function callChat(body: unknown, env: Partial<Env> = {}) {
  return worker.fetch(new Request("https://worker.test/chat", { method: "POST", body: JSON.stringify(body) }), makeEnv(env));
}

function claudeAnswer(text: string) {
  return jsonAnswer({ type: "message", role: "assistant", content: [{ type: "text", text }], stop_reason: "end_turn", usage: { input_tokens: 1000, output_tokens: 100 } });
}

/** A fetch that answers Claude at once and never answers GLM, failing only when GLM's try is aborted. */
function stubGLMThatNeverAnswers(abortedAfter: number[]) {
  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
    const address = String(input instanceof Request ? input.url : input);
    if (address.includes("anthropic.com")) return claudeAnswer("click Notes");
    const startedAt = Date.now();
    return await new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => {
        abortedAfter.push(Date.now() - startedAt);
        reject(new DOMException("The operation was aborted", "AbortError"));
      });
    });
  });
}

describe("screen step tries", () => {
  it("defaults to 8 seconds", () => {
    expect(DEFAULT_SCREEN_STEP_ATTEMPT_SECONDS).toBe(8);
    expect(screenStepAttemptMilliseconds(undefined)).toBe(8000);
    expect(screenStepAttemptMilliseconds("")).toBe(8000);
  });

  it("takes a setting from 1 to 60 seconds", () => {
    expect(screenStepAttemptMilliseconds("5")).toBe(5000);
    expect(screenStepAttemptMilliseconds("1")).toBe(1000);
    expect(screenStepAttemptMilliseconds("2.5")).toBe(2500);
    expect(screenStepAttemptMilliseconds("60")).toBe(60000);
  });

  it("ignores a setting that isn't a sensible number", () => {
    for (const badSetting of ["abc", "0", "0.5", "61", "-3", "NaN"]) {
      expect(screenStepAttemptMilliseconds(badSetting)).toBe(8000);
    }
  });

  it("cuts a provider's tries only when they are longer than the limit", () => {
    const glm = zaiProvider("key");
    expect(glm.attemptTimeoutMilliseconds).toBe(45_000);
    expect(withAttemptLimit(glm, 8000).attemptTimeoutMilliseconds).toBe(8000);
    expect(withAttemptLimit(glm, 60_000)).toBe(glm);
    expect(withAttemptLimit(glm, undefined)).toBe(glm);
    // The original provider is left as it was.
    expect(glm.attemptTimeoutMilliseconds).toBe(45_000);
  });

  it("never hands a screen step to Claude by default, even when GLM is slow", async () => {
    const abortedAfter: number[] = [];
    stubGLMThatNeverAnswers(abortedAfter);
    const response = await callChat(
      { provider: "screen", contents: [screenshotTurn()] },
      { ZAI_API_KEY: "zai", ANTHROPIC_API_KEY: "claude", SCREEN_STEP_ATTEMPT_SECONDS: "1" }
    );
    expect(response.status).toBe(503);
    expect(abortedAfter).toHaveLength(1);
  });

  it("hands a screen step to Claude when GLM doesn't answer within the limit and SCREEN_PROVIDER_ORDER says so", async () => {
    const abortedAfter: number[] = [];
    stubGLMThatNeverAnswers(abortedAfter);
    const startedAt = Date.now();
    const response = await callChat(
      { provider: "screen", contents: [screenshotTurn()] },
      { ZAI_API_KEY: "zai", ANTHROPIC_API_KEY: "claude", SCREEN_STEP_ATTEMPT_SECONDS: "1", SCREEN_PROVIDER_ORDER: "glm,claude" }
    );
    expect(response.status).toBe(200);
    const answer = await sseJSON(response);
    expect(answer.modelVersion).toBe("claude/claude-haiku-5-5");
    expect(answer.candidates[0].content.parts[0].text).toBe("click Notes");
    expect(abortedAfter).toHaveLength(1);
    expect(abortedAfter[0]).toBeGreaterThanOrEqual(900);
    expect(Date.now() - startedAt).toBeLessThan(5000);
  });

  it("leaves other asks with pictures on GLM's own longer try", async () => {
    let glmSignal: AbortSignal | null | undefined;
    vi.stubGlobal("fetch", async (_input: RequestInfo | URL, init?: RequestInit) => {
      glmSignal = init?.signal;
      return chatAnswer({ role: "assistant", content: "there" });
    });
    const response = await callChat({ contents: [screenshotTurn()] }, { ZAI_API_KEY: "zai", SCREEN_STEP_ATTEMPT_SECONDS: "1" });
    expect(response.status).toBe(200);
    // Still answering after the screen limit would have fired: not cut.
    await new Promise((resolve) => setTimeout(resolve, 1100));
    expect(glmSignal?.aborted).toBe(false);
  });

  it("answers 503 when no provider answers a screen step in time", async () => {
    const abortedAfter: number[] = [];
    vi.stubGlobal("fetch", async (_input: RequestInfo | URL, init?: RequestInit) => {
      return await new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => {
          abortedAfter.push(1);
          reject(new DOMException("aborted", "AbortError"));
        });
      });
    });
    const response = await callChat({ provider: "screen", contents: [screenshotTurn()] }, { ZAI_API_KEY: "zai", GROQ_API_KEY: "groq", SCREEN_STEP_ATTEMPT_SECONDS: "1" });
    expect(response.status).toBe(503);
    // GLM, then Groq's vision model: each cut to the limit.
    expect(abortedAfter.length).toBe(2);
  });
});

describe("model prices", () => {
  it("knows Claude Haiku 5.5 by default", () => {
    expect(DEFAULT_MODEL_PRICES).toContain("claude-haiku-5-5");
    expect(modelPrices()["claude-haiku-5-5"]).toEqual({ inputDollarsPerMillion: 0.1, outputDollarsPerMillion: 0.5 });
  });

  it("adds and overrides prices from the setting", () => {
    const prices = modelPrices("glm-5.3-flash=0.05/0.4, claude-haiku-5-5 = 0.2/1");
    expect(prices["glm-5.3-flash"]).toEqual({ inputDollarsPerMillion: 0.05, outputDollarsPerMillion: 0.4 });
    expect(prices["claude-haiku-5-5"]).toEqual({ inputDollarsPerMillion: 0.2, outputDollarsPerMillion: 1 });
  });

  it("skips entries that aren't model=in/out", () => {
    const prices = modelPrices("broken, =1/2, glm=abc/1, glm-x=1, , qwen/qwen3.8-27b=0.1/0.2");
    expect(Object.keys(prices).sort()).toEqual(["claude-haiku-5-5", "glm-5.3-flash", "qwen/qwen3.8-27b"]);
  });

  it("matches model names whatever their case", () => {
    expect(modelPrices("GLM-5.3-Flash=1/2")["glm-5.3-flash"]).toBeDefined();
  });
});

describe("answer usage", () => {
  it("prices tokens per million", () => {
    const usage = answerUsage("claude", "claude-haiku-5-5", { promptTokenCount: 1_000_000, candidatesTokenCount: 200_000 }, 1234);
    expect(usage).toEqual({ provider: "claude", model: "claude-haiku-5-5", inputTokens: 1_000_000, outputTokens: 200_000, seconds: 1.23, estimatedDollars: 0.2 });
  });

  it("says the cost is unknown for a model without a price", () => {
    expect(answerUsage("groq", "openai/gpt-oss-20b", { promptTokenCount: 10, candidatesTokenCount: 5 }, 800).estimatedDollars).toBeNull();
    // GLM-5.3-Flash has its regular price built in now.
    expect(answerUsage("glm", "glm-5.3-flash", { promptTokenCount: 1_000_000, candidatesTokenCount: 1_000_000 }, 800).estimatedDollars).toBeCloseTo(0.65);
  });

  it("uses a price from the setting", () => {
    expect(answerUsage("glm", "glm-5.3-flash", { promptTokenCount: 1_000_000, candidatesTokenCount: 0 }, 1, "glm-5.3-flash=0.5/1").estimatedDollars).toBe(0.5);
  });

  it("counts missing token numbers as zero", () => {
    const usage = answerUsage("groq", "openai/gpt-oss-20b", undefined, 0);
    expect(usage.inputTokens).toBe(0);
    expect(usage.outputTokens).toBe(0);
    expect(usage.seconds).toBe(0);
  });

  it("rides on every answer and is logged once", async () => {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    fakeFetch([["groq.com", chatAnswer({ role: "assistant", content: "hi" })]]);
    const response = await answerWithProvider(groqProvider("key"), { contents: [userText("hello")] }, true, { pricesSetting: "openai/gpt-oss-120b=1/2" });
    const answer = await sseJSON(response!);
    expect(answer.dottieUsage).toMatchObject({ provider: "groq", model: "openai/gpt-oss-120b", inputTokens: 5, outputTokens: 7 });
    expect(answer.dottieUsage.estimatedDollars).toBeCloseTo((5 * 1 + 7 * 2) / 1_000_000, 10);
    const usageLines = logSpy.mock.calls.map((call) => String(call[0])).filter((line) => line.startsWith("[usage] "));
    expect(usageLines).toHaveLength(1);
    expect(JSON.parse(usageLines[0].slice("[usage] ".length)).model).toBe("openai/gpt-oss-120b");
  });

  it("reaches the app through /chat with the Worker's prices", async () => {
    fakeFetch([["anthropic.com", claudeAnswer("done")]]);
    const response = await callChat({ provider: "request", contents: [userText("open notes")] }, { ANTHROPIC_API_KEY: "claude" });
    const answer = await sseJSON(response);
    expect(answer.dottieUsage).toMatchObject({ provider: "claude", model: "claude-haiku-5-5", inputTokens: 1000, outputTokens: 100 });
    expect(answer.dottieUsage.estimatedDollars).toBeCloseTo((1000 * 0.1 + 100 * 0.5) / 1_000_000, 10);
  });

  it("uses MODEL_PRICES from the Worker's settings", async () => {
    fakeFetch([["z.ai", chatAnswer({ role: "assistant", content: "ok" })]]);
    const response = await callChat({ contents: [screenshotTurn()] }, { ZAI_API_KEY: "zai", MODEL_PRICES: "glm-5.3-flash=1000000/0" });
    const answer = await sseJSON(response);
    expect(answer.dottieUsage.model).toBe("glm-5.3-flash");
    expect(answer.dottieUsage.estimatedDollars).toBe(5);
  });
});

describe("screenshots sent with a screen step", () => {
  const picture = () => imagePart(pngBase64(64, 40));
  const stepTurns = (count: number) =>
    Array.from({ length: count }, () => [
      { role: "model", parts: [{ functionCall: { name: "click", args: {} } }] },
      { role: "user", parts: [{ functionResponse: { name: "click", response: {} } }, picture()] },
    ]).flat();
  const pictureCount = (body: Record<string, unknown>) =>
    JSON.stringify(body).split('"inlineData"').length - 1;

  it("keeps 2 by default and takes 1 to 5 from the setting", () => {
    expect(DEFAULT_SCREEN_STEP_SCREENSHOTS).toBe(2);
    expect(screenStepScreenshotCount(undefined)).toBe(2);
    expect(screenStepScreenshotCount("1")).toBe(1);
    expect(screenStepScreenshotCount("5")).toBe(5);
    for (const badSetting of ["", "0", "6", "2.5", "abc", "-1"]) {
      expect(screenStepScreenshotCount(badSetting)).toBe(2);
    }
  });

  it("keeps only the newest screenshots and leaves a note for the rest", () => {
    const body = { contents: [{ role: "user", parts: [{ text: "open notes" }, picture()] }, ...stepTurns(4)] };
    const kept = keepingNewestScreenshots(body, 2);
    expect(pictureCount(kept)).toBe(2);
    const contents = kept.contents as Array<{ parts: Array<Record<string, unknown>> }>;
    // The newest two turns keep their pictures; the first turn's is a note now.
    expect(contents[contents.length - 1].parts[1].inlineData).toBeDefined();
    expect(contents[contents.length - 3].parts[1].inlineData).toBeDefined();
    expect(contents[0].parts[1]).toEqual({ text: "(an earlier screenshot, left out)" });
    // Everything else is untouched, and the original body is left as it was.
    expect(contents[0].parts[0]).toEqual({ text: "open notes" });
    expect(pictureCount(body)).toBe(5);
  });

  it("always keeps pictures the user shared before the first screenshot", () => {
    const sharedPicture = picture();
    const body = { contents: [{ role: "user", parts: [sharedPicture, { text: "grab the golden sword" }, picture()] }, ...stepTurns(3)] };
    const kept = keepingNewestScreenshots(body, 1);
    const contents = kept.contents as Array<{ parts: Array<Record<string, unknown>> }>;
    expect(contents[0].parts[0]).toEqual(sharedPicture);
    expect(pictureCount(kept)).toBe(2);
  });

  it("leaves a body with few enough screenshots as it was", () => {
    const body = { contents: [screenshotTurn()] };
    expect(keepingNewestScreenshots(body, 2)).toEqual(body);
    expect(keepingNewestScreenshots({}, 2)).toEqual({ contents: [] });
  });

  it("sends GLM only the newest screenshots of a screen step", async () => {
    let sentToGLM = "";
    vi.stubGlobal("fetch", async (_input: RequestInfo | URL, init?: RequestInit) => {
      sentToGLM = String(init?.body ?? "");
      return chatAnswer({ role: "assistant", content: "ok" });
    });
    const contents = [{ role: "user", parts: [{ text: "open notes" }, imagePart(pngBase64(1440, 900))] }, ...stepTurns(4)];
    const response = await callChat({ provider: "screen", contents }, { ZAI_API_KEY: "zai" });
    expect(response.status).toBe(200);
    expect(sentToGLM.split("\"type\":\"image_url\"").length - 1).toBe(2);
    expect(sentToGLM).toContain("an earlier screenshot, left out");
  });

  it("leaves other asks with pictures their screenshots", async () => {
    let sentToGLM = "";
    vi.stubGlobal("fetch", async (_input: RequestInfo | URL, init?: RequestInit) => {
      sentToGLM = String(init?.body ?? "");
      return chatAnswer({ role: "assistant", content: "ok" });
    });
    const contents = [{ role: "user", parts: [{ text: "what changed?" }, picture()] }, ...stepTurns(3)];
    await callChat({ contents }, { ZAI_API_KEY: "zai" });
    expect(sentToGLM.split("\"type\":\"image_url\"").length - 1).toBe(4);
  });
});
