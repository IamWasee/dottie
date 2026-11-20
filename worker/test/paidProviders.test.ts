import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  ANTHROPIC_VERSION,
  DEFAULT_ANTHROPIC_ANSWER_TOKENS,
  fromAnthropicResponse,
  imageBlockFromDataURL,
  toAnthropicRequest,
} from "../src/anthropicMessages";
import {
  anthropicProvider,
  answerWithProvider,
  toChatRequest,
  zaiProvider,
  DEFAULT_ANTHROPIC_MODELS,
  DEFAULT_ZAI_MODELS,
} from "../src/chatCompletions";
import worker, { paidProviders } from "../src/index";
import type { Env } from "../src/index";
import { chatAnswer, fakeFetch, imagePart, jsonAnswer, makeEnv, pngBase64, sseJSON } from "./helpers";

beforeEach(() => {
  vi.spyOn(console, "warn").mockImplementation(() => {});
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

const userText = (text: string) => ({ role: "user", parts: [{ text }] });
const sseAnswer = (text: string) => new Response(`data: ${JSON.stringify({ candidates: [{ content: { parts: [{ text }] } }] })}\r\n\r\n`, { headers: { "content-type": "text/event-stream" } });

/** A Messages API answer, as Claude sends it. */
function claudeAnswer(content: Array<Record<string, unknown>>, extra: Record<string, unknown> = {}) {
  return jsonAnswer({ type: "message", role: "assistant", content, stop_reason: "end_turn", usage: { input_tokens: 10, output_tokens: 4 }, ...extra });
}

function call(path: string, body: unknown, env: Partial<Env> = {}) {
  return worker.fetch(new Request(`https://worker.test${path}`, { method: "POST", body: JSON.stringify(body) }), makeEnv(env));
}

describe("imageBlockFromDataURL", () => {
  it("turns a base64 data URL into Claude's image block", () => {
    expect(imageBlockFromDataURL("data:image/png;base64,QUJD")).toEqual({ type: "image", source: { type: "base64", media_type: "image/png", data: "QUJD" } });
  });

  it("refuses anything that isn't a base64 data URL", () => {
    expect(imageBlockFromDataURL("https://example.com/a.png")).toBeUndefined();
    expect(imageBlockFromDataURL("data:image/png,raw")).toBeUndefined();
    expect(imageBlockFromDataURL(42)).toBeUndefined();
  });
});

describe("toAnthropicRequest", () => {
  it("puts the system text on its own and starts with the user", () => {
    const request = toAnthropicRequest({ messages: [{ role: "system", content: "Be brief." }, { role: "user", content: "hi" }] });
    expect(request.system).toBe("Be brief.");
    expect(request.messages).toEqual([{ role: "user", content: [{ type: "text", text: "hi" }] }]);
    expect(request.max_tokens).toBe(DEFAULT_ANTHROPIC_ANSWER_TOKENS);
  });

  it("reads a system message given as parts", () => {
    const request = toAnthropicRequest({ messages: [{ role: "system", content: [{ type: "text", text: "rules" }] }, { role: "user", content: "x" }] });
    expect(request.system).toBe("rules");
  });

  it("adds a user turn when the conversation starts with the assistant or is empty", () => {
    expect((toAnthropicRequest({ messages: [{ role: "assistant", content: "hello" }] }).messages as any[])[0]).toEqual({ role: "user", content: [{ type: "text", text: "Go on." }] });
    expect((toAnthropicRequest({}).messages as any[])).toHaveLength(1);
  });

  it("turns pictures, tool calls and tool results into Claude's blocks", () => {
    const request = toAnthropicRequest({
      messages: [
        { role: "user", content: [{ type: "text", text: "look" }, { type: "image_url", image_url: { url: "data:image/jpeg;base64,AAAA" } }, { type: "image_url", image_url: { url: "https://x" } }] },
        { role: "assistant", content: "clicking", tool_calls: [{ id: "call_1", type: "function", function: { name: "click", arguments: '{"x":5}' } }, { function: {} }] },
        { role: "tool", tool_call_id: "call_1", content: '{"ok":true}' },
        { role: "user", content: "next" },
      ],
    });
    const messages = request.messages as any[];
    expect(messages[0].content[1]).toEqual({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: "AAAA" } });
    expect(messages[0].content).toHaveLength(2);
    expect(messages[1].content).toEqual([{ type: "text", text: "clicking" }, { type: "tool_use", id: "call_1", name: "click", input: { x: 5 } }]);
    // The result and the next user text share one user turn, result first.
    expect(messages[2]).toEqual({ role: "user", content: [{ type: "tool_result", tool_use_id: "call_1", content: '{"ok":true}' }, { type: "text", text: "next" }] });
    expect(messages).toHaveLength(3);
  });

  it("keeps tool results first when text came before them in the same turn", () => {
    const request = toAnthropicRequest({
      messages: [
        { role: "user", content: "start" },
        { role: "assistant", content: null, tool_calls: [{ id: "a", function: { name: "f", arguments: "not json" } }] },
        { role: "user", content: "note" },
        { role: "tool", tool_call_id: "a", content: "" },
      ],
    });
    const messages = request.messages as any[];
    expect(messages[1].content[0].input).toEqual({});
    expect(messages[2].content.map((block: any) => block.type)).toEqual(["tool_result", "text"]);
    expect(messages[2].content[0].content).toBe("{}");
  });

  it("gives a tool call without an id one, and a call whose arguments aren't an object empty input", () => {
    const request = toAnthropicRequest({ messages: [{ role: "user", content: "go" }, { role: "assistant", tool_calls: [{ function: { name: "f", arguments: "[1]" } }] }, { role: "tool", content: [{ a: 1 }] }] });
    const messages = request.messages as any[];
    expect(messages[1].content[0].id).toMatch(/^call_/);
    expect(messages[1].content[0].input).toEqual({});
    expect(messages[2].content[0]).toMatchObject({ tool_use_id: "", content: '[{"a":1}]' });
  });

  it("carries tools, tool choice, answer size, temperature and JSON replies", () => {
    const base = { messages: [{ role: "user", content: "x" }], tools: [{ type: "function", function: { name: "click", description: "Click", parameters: { type: "object", properties: { x: { type: "number" } } } } }, { type: "function", function: { name: "bare" } }, { function: {} }] };
    const required = toAnthropicRequest({ ...base, tool_choice: "required", max_tokens: 99, temperature: 1.7, response_format: { type: "json_object" } });
    expect(required.tools).toEqual([
      { name: "click", description: "Click", input_schema: { type: "object", properties: { x: { type: "number" } } } },
      { name: "bare", description: "", input_schema: { type: "object", properties: {} } },
    ]);
    expect(required.tool_choice).toEqual({ type: "any" });
    expect(required.max_tokens).toBe(99);
    expect(required.temperature).toBe(1);
    expect(required.system).toContain("only the JSON object");
    expect(toAnthropicRequest({ ...base, tool_choice: "none" }).tool_choice).toEqual({ type: "none" });
    expect(toAnthropicRequest({ ...base, tool_choice: "auto", temperature: -1 })).toMatchObject({ tool_choice: { type: "auto" }, temperature: 0 });
  });

  it("works end to end from a Gemini body with a picture and a tool", () => {
    const chatRequest = toChatRequest({
      systemInstruction: { parts: [{ text: "You run screen jobs." }] },
      contents: [{ role: "user", parts: [{ text: "open mail" }, imagePart(pngBase64(100, 50))] }],
      tools: [{ functionDeclarations: [{ name: "click", parameters: { type: "OBJECT", properties: { x: { type: "NUMBER" } } } }] }],
      toolConfig: { functionCallingConfig: { mode: "ANY" } },
    });
    const request = toAnthropicRequest(chatRequest);
    expect(request.system).toBe("You run screen jobs.");
    expect((request.messages as any[])[0].content.map((block: any) => block.type)).toEqual(["text", "image"]);
    expect((request.tools as any[])[0].input_schema.properties.x.type).toBe("number");
    expect(request.tool_choice).toEqual({ type: "any" });
  });
});

describe("fromAnthropicResponse", () => {
  it("turns text and tool use into a chat answer with usage", () => {
    const chat = fromAnthropicResponse({
      content: [{ type: "text", text: "On it." }, { type: "tool_use", id: "t1", name: "click", input: { x: 1 } }, { type: "thinking", thinking: "hm" }, { type: "tool_use", id: "t2", name: "noinput" }],
      stop_reason: "tool_use",
      usage: { input_tokens: 10, output_tokens: 5, cache_read_input_tokens: 3, cache_creation_input_tokens: 2 },
    }) as any;
    expect(chat.choices[0].message.content).toBe("On it.");
    expect(chat.choices[0].message.tool_calls).toEqual([
      { id: "t1", type: "function", function: { name: "click", arguments: '{"x":1}' } },
      { id: "t2", type: "function", function: { name: "noinput", arguments: "{}" } },
    ]);
    expect(chat.choices[0].finish_reason).toBe("stop");
    expect(chat.usage).toEqual({ prompt_tokens: 15, completion_tokens: 5, total_tokens: 20 });
  });

  it("marks a cut-off answer and copes with an empty one", () => {
    expect((fromAnthropicResponse({ content: [{ type: "text", text: "half" }], stop_reason: "max_tokens" }) as any).choices[0].finish_reason).toBe("length");
    const empty = fromAnthropicResponse({}) as any;
    expect(empty.choices[0].message).toEqual({ content: "" });
    expect(empty.usage.total_tokens).toBe(0);
  });
});

describe("anthropicProvider and zaiProvider", () => {
  it("default to Haiku and GLM-5.3-Flash, with thinking off", () => {
    const claude = anthropicProvider("k");
    expect(claude.textModels).toEqual([DEFAULT_ANTHROPIC_MODELS]);
    expect(claude.visionModels).toEqual(["claude-haiku-5-5"]);
    expect(claude.format).toBe("anthropic");
    expect(claude.usesPixelBoxes).toBe(true);
    expect(claude.extrasForModel("x")).toEqual({ thinking: { type: "disabled" } });
    const glm = zaiProvider("k");
    expect(glm.textModels).toEqual([DEFAULT_ZAI_MODELS]);
    expect(glm.apiURL).toContain("api.z.ai");
    expect(glm.format).toBeUndefined();
    expect(glm.extrasForModel("x")).toEqual({ thinking: { type: "disabled" } });
  });

  it("take model lists from settings", () => {
    expect(anthropicProvider("k", "a, b").textModels).toEqual(["a", "b"]);
    expect(zaiProvider("k", "g1,g2").visionModels).toEqual(["g1", "g2"]);
  });
});

describe("answerWithProvider with Claude", () => {
  it("asks the Messages API with Claude's headers and answers in Gemini's shape", async () => {
    const calls = fakeFetch([["api.anthropic.com", claudeAnswer([{ type: "text", text: "hello" }])]]);
    const response = await answerWithProvider(anthropicProvider("claude-key"), { contents: [userText("hi")] }, false);
    const gemini = (await response!.json()) as any;
    expect(gemini.candidates[0].content.parts[0].text).toBe("hello");
    expect(gemini.modelVersion).toBe("claude/claude-haiku-5-5");
    expect(gemini.usageMetadata).toMatchObject({ promptTokenCount: 10, candidatesTokenCount: 4 });
    expect(calls[0].url).toBe("https://api.anthropic.com/v1/messages");
    expect(calls[0].headers.get("x-api-key")).toBe("claude-key");
    expect(calls[0].headers.get("anthropic-version")).toBe(ANTHROPIC_VERSION);
    expect(calls[0].headers.get("authorization")).toBeNull();
    expect(calls[0].json).toMatchObject({ model: "claude-haiku-5-5", thinking: { type: "disabled" }, max_tokens: DEFAULT_ANTHROPIC_ANSWER_TOKENS });
    expect(calls[0].json.messages).toEqual([{ role: "user", content: [{ type: "text", text: "hi" }] }]);
  });

  it("turns Claude's tool use into a Gemini function call", async () => {
    fakeFetch([["api.anthropic.com", claudeAnswer([{ type: "tool_use", id: "t1", name: "open_app", input: { name: "Mail" } }])]]);
    const response = await answerWithProvider(anthropicProvider("k"), { contents: [userText("open mail")], tools: [{ functionDeclarations: [{ name: "open_app" }] }] }, true);
    const part = (await sseJSON(response!)).candidates[0].content.parts[0];
    expect(part.functionCall).toEqual({ name: "open_app", args: { name: "Mail" }, id: "t1" });
  });

  it("asks Claude for pixel boxes and turns them back into box_2d", async () => {
    const calls = fakeFetch([["api.anthropic.com", claudeAnswer([{ type: "text", text: '{"box_px":[10,20,30,40]}' }])]]);
    const body = {
      contents: [{ role: "user", parts: [{ text: 'Find it. Answer {"box_2d":[ymin,xmin,ymax,xmax]}' }, imagePart(pngBase64(100, 200))] }],
    };
    const response = await answerWithProvider(anthropicProvider("k"), body, false);
    expect(calls[0].bodyText).toContain("box_px");
    const text = ((await response!.json()) as any).candidates[0].content.parts[0].text;
    expect(JSON.parse(text).box_2d).toEqual([100, 100, 200, 300]);
  });

  it("tries again without thinking switched off after a 400", async () => {
    const calls = fakeFetch([["api.anthropic.com", (recorded) => (recorded.json.thinking ? new Response("no", { status: 400 }) : claudeAnswer([{ type: "text", text: "ok" }]))]]);
    const response = await answerWithProvider(anthropicProvider("k"), { contents: [userText("hi")] }, false);
    expect(((await response!.json()) as any).candidates[0].content.parts[0].text).toBe("ok");
    expect(calls).toHaveLength(2);
  });

  it("gives up when Claude answers with nothing usable", async () => {
    fakeFetch([["api.anthropic.com", claudeAnswer([])]]);
    expect(await answerWithProvider(anthropicProvider("k"), { contents: [userText("hi")] }, false)).toBeUndefined();
  });
});

describe("answerWithProvider with GLM", () => {
  it("asks Z.ai in the chat format with a bearer key and leaves boxes as asked", async () => {
    const calls = fakeFetch([["api.z.ai", chatAnswer({ content: '{"box_2d":[1,2,3,4]}' })]]);
    const body = { contents: [{ role: "user", parts: [{ text: "box_2d please" }, imagePart(pngBase64(10, 10))] }] };
    const response = await answerWithProvider(zaiProvider("zai-key"), body, false);
    expect(calls[0].headers.get("authorization")).toBe("Bearer zai-key");
    expect(calls[0].json).toMatchObject({ model: "glm-5.3-flash", thinking: { type: "disabled" } });
    expect(calls[0].bodyText).not.toContain("box_px");
    expect(((await response!.json()) as any).modelVersion).toBe("glm/glm-5.3-flash");
  });
});

describe("paidProviders", () => {
  const picture = { contents: [{ role: "user", parts: [{ text: "x" }, imagePart(pngBase64(10, 10))] }] };
  const text = { contents: [userText("x")] };

  it("is empty without paid keys", () => {
    expect(paidProviders(makeEnv(), text)).toEqual([]);
  });

  it("puts GLM first for pictures and Claude first for text", () => {
    const env = makeEnv({ ANTHROPIC_API_KEY: "a", ZAI_API_KEY: "z" });
    expect(paidProviders(env, picture).map((provider) => provider.name)).toEqual(["glm", "claude"]);
    expect(paidProviders(env, text).map((provider) => provider.name)).toEqual(["claude", "glm"]);
  });

  it("follows the order settings, skipping unknown and repeated names", () => {
    const env = makeEnv({ ANTHROPIC_API_KEY: "a", ZAI_API_KEY: "z", PICTURE_PROVIDER_ORDER: "Claude, jev, claude", TEXT_PROVIDER_ORDER: "glm" });
    expect(paidProviders(env, picture).map((provider) => provider.name)).toEqual(["claude"]);
    expect(paidProviders(env, text).map((provider) => provider.name)).toEqual(["glm"]);
  });

  it("uses only GLM for a helper's text turn, and follows HELPER_PROVIDER_ORDER", () => {
    const env = makeEnv({ ANTHROPIC_API_KEY: "a", ZAI_API_KEY: "z" });
    expect(paidProviders(env, text, true).map((provider) => provider.name)).toEqual(["glm"]);
    expect(paidProviders(env, picture, true).map((provider) => provider.name)).toEqual(["glm", "claude"]);
    const reordered = makeEnv({ ANTHROPIC_API_KEY: "a", ZAI_API_KEY: "z", HELPER_PROVIDER_ORDER: "claude", TEXT_PROVIDER_ORDER: "glm" });
    expect(paidProviders(reordered, text, true).map((provider) => provider.name)).toEqual(["claude"]);
  });

  it("uses only the providers with keys", () => {
    expect(paidProviders(makeEnv({ ZAI_API_KEY: "z" }), text).map((provider) => provider.name)).toEqual(["glm"]);
  });
});

describe("/chat with paid keys", () => {
  it("answers a text ask from Claude without touching Groq or Gemini", async () => {
    const calls = fakeFetch([["api.anthropic.com", claudeAnswer([{ type: "text", text: "Paris." }])]]);
    const response = await call("/chat", { provider: "groq", contents: [userText("capital of France?")] }, { ANTHROPIC_API_KEY: "a", ZAI_API_KEY: "z", GROQ_API_KEY: "g" });
    expect((await sseJSON(response)).candidates[0].content.parts[0].text).toBe("Paris.");
    expect(calls).toHaveLength(1);
    expect(calls[0].json.provider).toBeUndefined();
  });

  it("sends a screen step with a picture to GLM first, then Claude when GLM is down", async () => {
    const calls = fakeFetch([
      ["api.z.ai", new Response("down", { status: 500 })],
      ["api.anthropic.com", claudeAnswer([{ type: "text", text: "clicked" }])],
    ]);
    const body = { contents: [{ role: "user", parts: [{ text: "next step" }, imagePart(pngBase64(10, 10))] }] };
    const response = await call("/chat", body, { ANTHROPIC_API_KEY: "a", ZAI_API_KEY: "z" });
    expect((await sseJSON(response)).candidates[0].content.parts[0].text).toBe("clicked");
    expect(calls.map((recorded) => new URL(recorded.url).host)).toEqual(["api.z.ai", "api.anthropic.com"]);
  });

  it("sends only the newest screenshots of a long screen job", async () => {
    const calls = fakeFetch([["api.z.ai", chatAnswer({ content: "ok" })]]);
    const contents = Array.from({ length: 10 }, (_, index) => ({ role: index % 2 === 0 ? "user" : "model", parts: index % 2 === 0 ? [{ text: `step ${index}` }, imagePart(pngBase64(10, 10))] : [{ text: "done" }] }));
    await call("/chat", { contents }, { ZAI_API_KEY: "z" });
    const sentPictures = calls[0].bodyText.match(/data:image/g) ?? [];
    expect(sentPictures.length).toBeLessThanOrEqual(5);
  });

  it("skips a provider the request is too big for", async () => {
    const calls = fakeFetch([["/models/chat-model:", sseAnswer("gemini")]]);
    await call("/chat", { contents: [userText("a".repeat(700_000))] }, { ANTHROPIC_API_KEY: "a" });
    expect(calls.every((recorded) => recorded.url.includes("generativelanguage"))).toBe(true);
  });

  it("falls back to what's left when every paid provider fails", async () => {
    const calls = fakeFetch([
      ["api.anthropic.com", new Response("overloaded", { status: 529 })],
      ["/models/chat-model:", sseAnswer("gemini backup")],
    ]);
    const response = await call("/chat", { contents: [userText("hi")] }, { ANTHROPIC_API_KEY: "a" });
    expect((await sseJSON(response)).candidates[0].content.parts[0].text).toBe("gemini backup");
    expect(calls[0].url).toContain("anthropic");
  });
});

describe("/gemini (helpers) with paid keys", () => {
  const generatePath = "/gemini/v1beta/models/agent-model:generateContent";

  it("answers a helper's turn from GLM first when both keys are set", async () => {
    const calls = fakeFetch([["api.z.ai", chatAnswer({ content: "made it on GLM" })]]);
    const response = await call(generatePath, { contents: [userText("build it")] }, { ANTHROPIC_API_KEY: "a", ZAI_API_KEY: "z" });
    expect(((await response.json()) as any).candidates[0].content.parts[0].text).toBe("made it on GLM");
    expect(calls.map((recorded) => new URL(recorded.url).host)).toEqual(["api.z.ai"]);
  });

  it("never sends a helper's turn to Claude, even when GLM is down", async () => {
    const calls = fakeFetch([
      ["api.z.ai", new Response("down", { status: 500 })],
      ["/models/agent-model:", jsonAnswer({ candidates: [{ content: { parts: [{ text: "old path" }] } }] })],
    ]);
    await call(generatePath, { contents: [userText("build it")] }, { ANTHROPIC_API_KEY: "a", ZAI_API_KEY: "z" });
    expect(calls.some((recorded) => recorded.url.includes("anthropic"))).toBe(false);
  });

  it("answers a helper's turn from Claude only when HELPER_PROVIDER_ORDER says so", async () => {
    const calls = fakeFetch([["api.anthropic.com", claudeAnswer([{ type: "text", text: "made the site" }])]]);
    const response = await call(generatePath, { contents: [userText("build it")] }, { ANTHROPIC_API_KEY: "a", HELPER_PROVIDER_ORDER: "claude" });
    expect(((await response.json()) as any).candidates[0].content.parts[0].text).toBe("made the site");
    expect(calls).toHaveLength(1);
  });

  it("streams a helper's turn as one event", async () => {
    fakeFetch([["api.anthropic.com", claudeAnswer([{ type: "text", text: "streamed" }])]]);
    const response = await call("/gemini/v1beta/models/agent-model:streamGenerateContent?alt=sse", { contents: [userText("go")] }, { ANTHROPIC_API_KEY: "a", HELPER_PROVIDER_ORDER: "claude" });
    expect((await sseJSON(response)).candidates[0].content.parts[0].text).toBe("streamed");
  });

  it("goes on to Gemini when GLM can't answer", async () => {
    fakeFetch([
      ["api.z.ai", new Response("down", { status: 500 })],
      ["/models/agent-model:", jsonAnswer({ candidates: [{ content: { parts: [{ text: "gemini" }] } }] })],
    ]);
    const response = await call(generatePath, { contents: [userText("go")] }, { ZAI_API_KEY: "z" });
    expect(((await response.json()) as any).candidates[0].content.parts[0].text).toBe("gemini");
  });

  it("goes on to Gemini when the body isn't JSON", async () => {
    const calls = fakeFetch([["/models/agent-model:", jsonAnswer({ ok: true })]]);
    const response = await worker.fetch(new Request(`https://worker.test${generatePath}`, { method: "POST", body: "not json" }), makeEnv({ ZAI_API_KEY: "z" }));
    expect(response.status).toBe(200);
    expect(calls).toHaveLength(1);
  });

  it("leaves a helper set to Gemini on Gemini", async () => {
    const calls = fakeFetch([["/models/agent-model:", jsonAnswer({ ok: true })]]);
    await call("/gemini-only/v1beta/models/agent-model:generateContent", { contents: [userText("go")] }, { ANTHROPIC_API_KEY: "a" });
    expect(calls.every((recorded) => recorded.url.includes("generativelanguage"))).toBe(true);
  });
});

describe("GET /config", () => {
  it("shows Claude and GLM as off or with their models", async () => {
    const off = (await (await worker.fetch(new Request("https://worker.test/config"), makeEnv())).json()) as any;
    expect(off).toMatchObject({ claude: "off", glm: "off" });
    const on = (await (await worker.fetch(new Request("https://worker.test/config"), makeEnv({ ANTHROPIC_API_KEY: "a", ZAI_API_KEY: "z", ZAI_MODELS: "g" }))).json()) as any;
    expect(on).toMatchObject({ claude: "default", glm: "g" });
  });
});
