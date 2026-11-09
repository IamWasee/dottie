import { afterEach, describe, expect, it, vi } from "vitest";
import { isSameSecret, jsonResponse, readJSONObject, upstreamErrorResponse } from "../src/http";

afterEach(() => vi.restoreAllMocks());

describe("jsonResponse", () => {
  it("answers 200 with JSON by default", async () => {
    const response = jsonResponse({ ok: true });
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/json");
    expect(await response.json()).toEqual({ ok: true });
  });

  it("uses the status it is given", () => {
    expect(jsonResponse({ error: "no" }, 418).status).toBe(418);
  });

  it("writes null and arrays as JSON too", async () => {
    expect(await jsonResponse(null).text()).toBe("null");
    expect(await jsonResponse([1, 2]).text()).toBe("[1,2]");
  });
});

describe("readJSONObject", () => {
  const requestWith = (body: string | undefined) => new Request("https://worker.test/", { method: "POST", body });

  it("returns a JSON object", async () => {
    expect(await readJSONObject(requestWith('{"a":1}'))).toEqual({ a: 1 });
  });

  it("returns undefined for text that isn't JSON", async () => {
    expect(await readJSONObject(requestWith("not json"))).toBeUndefined();
  });

  it("returns undefined for an empty body", async () => {
    expect(await readJSONObject(requestWith(undefined))).toBeUndefined();
  });

  it.each(["[1,2]", '"text"', "42", "null", "true"])("returns undefined for JSON that isn't an object: %s", async (body) => {
    expect(await readJSONObject(requestWith(body))).toBeUndefined();
  });
});

describe("upstreamErrorResponse", () => {
  it("keeps the upstream status and body, and logs it", async () => {
    const logged = vi.spyOn(console, "error").mockImplementation(() => {});
    const response = await upstreamErrorResponse("/chat", new Response('{"error":"quota"}', { status: 429 }));
    expect(response.status).toBe(429);
    expect(await response.text()).toBe('{"error":"quota"}');
    expect(response.headers.get("content-type")).toBe("application/json");
    expect(logged).toHaveBeenCalledWith(expect.stringContaining("[/chat] upstream error 429"));
  });

  it("passes an empty error body on", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const response = await upstreamErrorResponse("/tts", new Response("", { status: 503 }));
    expect(response.status).toBe(503);
    expect(await response.text()).toBe("");
  });
});

describe("isSameSecret", () => {
  it("is true for the same text", () => {
    expect(isSameSecret("correct horse", "correct horse")).toBe(true);
  });

  it("is false when one character differs", () => {
    expect(isSameSecret("correct horsf", "correct horse")).toBe(false);
  });

  it("is false when the presented text is only the start of the secret", () => {
    expect(isSameSecret("correct", "correct horse")).toBe(false);
  });

  it("is false when the presented text is longer than the secret", () => {
    expect(isSameSecret("correct horse battery", "correct horse")).toBe(false);
  });

  it("is false for an empty presented text", () => {
    expect(isSameSecret("", "secret")).toBe(false);
  });

  it("compares text outside ASCII by its bytes", () => {
    expect(isSameSecret("pässwörd", "pässwörd")).toBe(true);
    expect(isSameSecret("passwörd", "pässwörd")).toBe(false);
  });
});
