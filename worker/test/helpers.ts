import { env } from "cloudflare:test";
import { vi } from "vitest";
import type { Env } from "../src/index";

/** The Worker's settings for a test: made-up keys, the real Durable Object binding, and any overrides. */
export function makeEnv(overrides: Partial<Env> = {}): Env {
  return {
    GEMINI_API_KEY: "test-gemini-key",
    GEMINI_CHAT_MODEL: "chat-model",
    GEMINI_HIGHER_MODEL: "higher-model",
    GEMINI_FALLBACK_MODELS: "backup-one,backup-two",
    PHONE_RELAY: (env as unknown as Env).PHONE_RELAY,
    ...overrides,
  };
}

export interface RecordedCall {
  url: string;
  method: string;
  headers: Headers;
  bodyText: string;
  /** The body parsed as JSON, or undefined when it isn't JSON. */
  json: any;
}

type FakeAnswer = Response | ((call: RecordedCall) => Response | Promise<Response>);

/**
 * Replaces `fetch` for one test. Each rule is [part of the address, answer];
 * the first rule whose text is in the address answers. A call no rule
 * matches fails the test, so nothing ever reaches the real internet.
 */
export function fakeFetch(rules: Array<[string | RegExp, FakeAnswer]>): RecordedCall[] {
  const recordedCalls: RecordedCall[] = [];
  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input as RequestInfo, init);
    // Read as bytes: the runtime warns about .text() on bodies that are forms or files.
    const bodyText = request.body ? new TextDecoder().decode(await request.arrayBuffer()) : "";
    let json: unknown;
    try {
      json = bodyText ? JSON.parse(bodyText) : undefined;
    } catch {
      json = undefined;
    }
    const call: RecordedCall = { url: request.url, method: request.method, headers: request.headers, bodyText, json };
    recordedCalls.push(call);
    // A signal that already fired (a timeout) fails the call, as real fetch does.
    if (init?.signal?.aborted) throw new DOMException("The operation was aborted", "AbortError");
    for (const [addressPart, answer] of rules) {
      const matches = typeof addressPart === "string" ? request.url.includes(addressPart) : addressPart.test(request.url);
      if (!matches) continue;
      return typeof answer === "function" ? await answer(call) : answer.clone();
    }
    throw new Error(`Unexpected fetch in a test: ${request.method} ${request.url}`);
  });
  return recordedCalls;
}

export function jsonAnswer(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

/** A Gemini generateContent answer with one text part. */
export function geminiTextAnswer(text: string): Response {
  return jsonAnswer({ candidates: [{ content: { role: "model", parts: [{ text }] } }] });
}

/** An OpenAI-style chat answer, as Groq and NIM send it. */
export function chatAnswer(message: Record<string, unknown>, extra: Record<string, unknown> = {}): Response {
  return jsonAnswer({ choices: [{ message, finish_reason: "stop" }], usage: { prompt_tokens: 5, completion_tokens: 7, total_tokens: 12 }, ...extra });
}

function base64FromBytes(bytes: number[]): string {
  return btoa(String.fromCharCode(...bytes));
}

function fourBytes(value: number): number[] {
  return [(value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff];
}

/** The first bytes of a PNG that say how big it is. */
export function pngHeaderBytes(width: number, height: number): number[] {
  return [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, ...fourBytes(width), ...fourBytes(height), 8, 2, 0, 0, 0];
}

/** A JPEG's start, an application segment, then the start-of-frame segment with its size. */
export function jpegHeaderBytes(width: number, height: number): number[] {
  return [
    0xff, 0xd8,
    0xff, 0xe0, 0x00, 0x04, 0x00, 0x00,
    0xff, 0xc0, 0x00, 0x0b, 0x08, (height >> 8) & 0xff, height & 0xff, (width >> 8) & 0xff, width & 0xff, 0x03, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
  ];
}

export function pngBase64(width: number, height: number): string {
  return base64FromBytes(pngHeaderBytes(width, height));
}

export function jpegBase64(width: number, height: number): string {
  return base64FromBytes(jpegHeaderBytes(width, height));
}

export function imagePart(base64Data: string, mimeType = "image/png") {
  return { inlineData: { mimeType, data: base64Data } };
}

/** Reads a one-event SSE response ("data: {...}") back into its JSON. */
export async function sseJSON(response: Response): Promise<any> {
  const text = await response.text();
  return JSON.parse(text.replace(/^data: /, "").trim());
}
