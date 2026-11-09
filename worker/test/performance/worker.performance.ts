import { afterAll, afterEach, describe, expect, it, vi } from "vitest";
import { fittedForProvider, groqProvider, pixelBoxConversion, toChatRequest, toGeminiResponse, estimatedTokens } from "../../src/chatCompletions";
import { fetchReadableText, htmlToText, meaningfulQueryWords, queryWordCoverage, searchBing } from "../../src/search";

/**
 * Each check runs the code many times and compares the middle (median) time
 * with a budget. Budgets are several times what a laptop needs, so a slow CI
 * machine passes but a change that makes something many times slower fails.
 * A Worker request gets 10 ms of CPU on the free plan and 30 s on the paid
 * one, so everything here should stay in the low milliseconds.
 */
const measurements: { name: string; medianMilliseconds: number; budgetMilliseconds: number }[] = [];

async function medianMilliseconds(runCount: number, work: () => unknown | Promise<unknown>): Promise<number> {
  // Warm up, so the first slow, uncompiled runs aren't counted.
  for (let warmUp = 0; warmUp < 5; warmUp += 1) await work();
  const durations: number[] = [];
  for (let run = 0; run < runCount; run += 1) {
    const startedAt = performance.now();
    await work();
    durations.push(performance.now() - startedAt);
  }
  durations.sort((first, second) => first - second);
  return durations[Math.floor(durations.length / 2)];
}

async function expectWithinBudget(name: string, budgetMilliseconds: number, work: () => unknown | Promise<unknown>, runCount = 30) {
  const median = await medianMilliseconds(runCount, work);
  measurements.push({ name, medianMilliseconds: median, budgetMilliseconds });
  expect(median, `${name} took ${median.toFixed(2)} ms (budget ${budgetMilliseconds} ms)`).toBeLessThan(budgetMilliseconds);
}

afterEach(() => vi.unstubAllGlobals());

afterAll(() => {
  console.log(
    ["", "Worker performance (median of the runs)", ...measurements.map((row) => `  ${row.name.padEnd(58)} ${row.medianMilliseconds.toFixed(3).padStart(9)} ms   budget ${row.budgetMilliseconds} ms`), ""].join("\n")
  );
});

/** A PNG header for a 1280×800 screenshot, padded to the size of a real one (about 300 KB of base64). */
function screenshotBase64(): string {
  const header = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 5, 0, 0, 0, 3, 32, 8, 2, 0, 0, 0];
  return btoa(String.fromCharCode(...header)) + "A".repeat(300_000);
}

/** A screen job as the app sends it: the task, then a model call and its result with a screenshot, `stepCount` times. */
function screenJobBody(stepCount: number): Record<string, unknown> {
  const picture = screenshotBase64();
  const contents: unknown[] = [{ role: "user", parts: [{ text: "Open the settings page and turn on dark mode. Answer with target_box_2d." }] }];
  for (let step = 0; step < stepCount; step += 1) {
    contents.push({ role: "model", parts: [{ functionCall: { name: "click", args: { target_box_2d: [100 + step, 200, 300, 400], reason: "the next button" } } }] });
    contents.push({ role: "user", parts: [{ functionResponse: { name: "click", response: { result: "clicked" } } }, { inlineData: { mimeType: "image/png", data: picture } }] });
  }
  return {
    systemInstruction: { parts: [{ text: "You operate a Mac. ".repeat(200) }] },
    contents,
    tools: [{ functionDeclarations: Array.from({ length: 12 }, (_, index) => ({ name: `tool_${index}`, description: "Does one thing on the screen. ".repeat(10), parameters: { type: "OBJECT", properties: { target_box_2d: { type: "ARRAY" } } } })) }],
  };
}

function longChatBody(turnCount: number): Record<string, unknown> {
  return {
    systemInstruction: { parts: [{ text: "You are Dottie. ".repeat(300) }] },
    contents: Array.from({ length: turnCount }, (_, index) => ({ role: index % 2 === 0 ? "user" : "model", parts: [{ text: `Turn ${index}: ${"some words ".repeat(40)}` }] })),
  };
}

describe("turning a request into Groq's format", () => {
  it("converts a 200-turn chat quickly", async () => {
    const body = longChatBody(200);
    await expectWithinBudget("toChatRequest, 200 text turns", 10, () => toChatRequest(body));
  });

  it("estimates the size of a 200-turn chat quickly", async () => {
    const body = longChatBody(200);
    await expectWithinBudget("estimatedTokens, 200 text turns", 5, () => estimatedTokens(body));
  });

  it("cuts a 30-step screen job (30 screenshots, 9 MB) down to fit", async () => {
    const body = screenJobBody(30);
    const groq = groqProvider("key");
    await expectWithinBudget("fittedForProvider, 30 steps with screenshots", 150, () => fittedForProvider(groq, body, true), 15);
  });

  it("switches a 3-screenshot request to pixel boxes", async () => {
    const body = fittedForProvider(groqProvider("key"), screenJobBody(3), false);
    await expectWithinBudget("pixelBoxConversion, 3 screenshots", 60, () => pixelBoxConversion(body), 15);
  });

  it("turns an answer with 20 tool calls back into Gemini's format", async () => {
    const chatResponse = {
      choices: [{ message: { content: "Working on it.", tool_calls: Array.from({ length: 20 }, (_, index) => ({ id: `call_${index}`, function: { name: "click", arguments: JSON.stringify({ target_box_px: [1, 2, 3, 4], reason: "x".repeat(200) }) } })) }, finish_reason: "stop" }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
    };
    await expectWithinBudget("toGeminiResponse, 20 tool calls", 5, () => toGeminiResponse(chatResponse, "groq/model"));
  });
});

describe("search", () => {
  const bigPage = `<html><head><script>${"var a = 1;".repeat(20_000)}</script><style>${".a{color:red}".repeat(5_000)}</style></head><body>${"<div><p>Some readable text &amp; more of it.</p></div>".repeat(6_000)}</body></html>`;

  it("pulls the readable text out of a 600 KB page", async () => {
    vi.stubGlobal("fetch", async () => new Response(bigPage, { headers: { "content-type": "text/html" } }));
    await expectWithinBudget("fetchReadableText, 600 KB page", 80, () => fetchReadableText("https://page.example/"), 15);
  });

  it("strips the tags from 300 KB of markup", async () => {
    const markup = "<div><p>Some readable text &amp; more of it.</p></div>".repeat(6_000);
    await expectWithinBudget("htmlToText, 300 KB", 40, () => htmlToText(markup), 15);
  });

  it("reads a Bing results page", async () => {
    const resultBlock = (index: number) =>
      `<li class="b_algo"><h2><a href="https://www.bing.com/ck/a?u=a1${btoa(`https://example.com/${index}`).replace(/=+$/, "")}&ntb=1">Result ${index}</a></h2><p>${"snippet words ".repeat(30)}</p></li>`;
    const page = `<html><body>${"<div>filler</div>".repeat(3_000)}${Array.from({ length: 10 }, (_, index) => resultBlock(index)).join("")}</body></html>`;
    vi.stubGlobal("fetch", async () => new Response(page, { headers: { "content-type": "text/html" } }));
    await expectWithinBudget("searchBing, parsing one results page", 15, () => searchBing("anything"));
  });

  it("scores results against a long query", async () => {
    const query = "what is the best way to grow tomatoes indoors during winter without a greenhouse in a small apartment ".repeat(3);
    const results = Array.from({ length: 6 }, (_, index) => ({ title: `Growing tomatoes indoors ${index}`, url: `https://example.com/${index}`, snippet: "winter apartment greenhouse ".repeat(20) }));
    await expectWithinBudget("meaningfulQueryWords + queryWordCoverage", 3, () => queryWordCoverage(meaningfulQueryWords(query), results));
  });
});
