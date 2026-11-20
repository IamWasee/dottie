import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_JEV_MODEL, JEV_API_URL, hasImageAssets, jevRequestBody } from "../src/jev";
import worker from "../src/index";
import type { Env } from "../src/index";
import { usageArea } from "../src/usageLimits";
import { fakeFetch, jsonAnswer, makeEnv } from "./helpers";

beforeEach(() => {
  vi.spyOn(console, "warn").mockImplementation(() => {});
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

function callJev(body: unknown, env: Partial<Env> = { JEV_API_KEY: "jev-key" }) {
  return worker.fetch(new Request("https://worker.test/jev", { method: "POST", body: typeof body === "string" ? body : JSON.stringify(body) }), makeEnv(env));
}

const boxQuestionBody = {
  state: { task: "click the first email", screen: "shot-1" },
  assets: { "shot-1": { type: "image", format: "jpeg", data_base64: "AAAA" } },
  questions: { target: { type: "box", instructions: "the first email in the list" } },
};

describe("jevRequestBody", () => {
  it("adds the default model and keeps everything else", () => {
    expect(jevRequestBody({ state: "x", questions: { done: { type: "noul" } } })).toEqual({ state: "x", questions: { done: { type: "noul" } }, model: DEFAULT_JEV_MODEL });
  });

  it("keeps a model the app chose, or uses the Worker's setting", () => {
    expect((jevRequestBody({ state: "x", questions: { a: { type: "noul" } }, model: "jev-1.14.0" }) as any).model).toBe("jev-1.14.0");
    expect((jevRequestBody({ state: "x", questions: { a: { type: "noul" } }, model: "" }, "jev-pinned") as any).model).toBe("jev-pinned");
  });

  it("refuses a body without questions or state", () => {
    expect(jevRequestBody({ state: "x" })).toContain("questions");
    expect(jevRequestBody({ state: "x", questions: {} })).toContain("questions");
    expect(jevRequestBody({ state: "x", questions: [] })).toContain("questions");
    expect(jevRequestBody({ questions: { a: { type: "noul" } } })).toBe("state is missing");
  });
});

describe("hasImageAssets", () => {
  it("is true only for image assets", () => {
    expect(hasImageAssets(boxQuestionBody)).toBe(true);
    expect(hasImageAssets({ assets: { a: { type: "audio" } } })).toBe(false);
    expect(hasImageAssets({ assets: { a: null } })).toBe(false);
    expect(hasImageAssets({})).toBe(false);
  });
});

describe("POST /jev", () => {
  it("is refused without a Jev key", async () => {
    const response = await callJev(boxQuestionBody, {});
    expect(response.status).toBe(503);
  });

  it("refuses a body that isn't a JSON object or lacks questions", async () => {
    expect((await callJev("not json")).status).toBe(400);
    expect((await callJev({ state: "x" })).status).toBe(400);
  });

  it("sends a box question with the key and the images header, and passes Jev's answer back", async () => {
    const answer = { model: "jev-1.14.0", answers: { target: { type: "box", box: { top: 0.1, bottom: 0.2, left: 0.3, right: 0.5 }, confidence: 0.9 } }, usage: { input_tokens: 900, output_tokens: 3 } };
    const calls = fakeFetch([[JEV_API_URL, jsonAnswer(answer)]]);
    const response = await callJev(boxQuestionBody);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(answer);
    expect(calls[0].headers.get("authorization")).toBe("Bearer jev-key");
    expect(calls[0].headers.get("TypeSafe-Danger-Zone-Images")).toBe("true");
    expect(calls[0].json.model).toBe("jev-latest");
    expect(calls[0].json.assets["shot-1"].data_base64).toBe("AAAA");
  });

  it("sends a text-only question without the images header, with the Worker's model", async () => {
    const calls = fakeFetch([[JEV_API_URL, jsonAnswer({ answers: { done: { type: "noul", noul: 0.97 } } })]]);
    await callJev({ state: "Inbox shows 0 unread", questions: { done: { type: "noul", instructions: "Is the inbox empty?" } } }, { JEV_API_KEY: "k", JEV_MODEL: "jev-1.14.0" });
    expect(calls[0].headers.get("TypeSafe-Danger-Zone-Images")).toBeNull();
    expect(calls[0].json.model).toBe("jev-1.14.0");
  });

  it("passes Jev's errors on with their status", async () => {
    fakeFetch([[JEV_API_URL, new Response('{"error":"overloaded"}', { status: 529 })]]);
    const response = await callJev(boxQuestionBody);
    expect(response.status).toBe(529);
    expect(await response.text()).toContain("overloaded");
  });

  it("answers 504 when Jev doesn't answer", async () => {
    vi.stubGlobal("fetch", async () => { throw new DOMException("timed out", "TimeoutError"); });
    const response = await callJev(boxQuestionBody);
    expect(response.status).toBe(504);
  });

  it("counts toward the install's chat limit", () => {
    expect(usageArea("POST", "/jev")).toBe("chat");
    expect(usageArea("GET", "/jev")).toBeUndefined();
  });

  it("shows on /config", async () => {
    const config = (await (await worker.fetch(new Request("https://worker.test/config"), makeEnv({ JEV_API_KEY: "k" }))).json()) as any;
    expect(config.jev).toBe("default");
  });
});
