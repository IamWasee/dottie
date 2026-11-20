import { afterEach, describe, expect, it, vi } from "vitest";
import {
  salvagedToolUseFailure,
  answerWithProvider,
  canAnswer,
  estimatedTokens,
  fittedForProvider,
  groqProvider,
  imageCount,
  lowercaseSchema,
  nimProvider,
  pictureSize,
  pixelBoxConversion,
  textWithGeminiBoxes,
  toChatRequest,
  toGeminiResponse,
  DEFAULT_GROQ_TEXT_MODELS,
  DEFAULT_GROQ_VISION_MODELS,
  DEFAULT_NIM_MODELS,
} from "../src/chatCompletions";
import { chatAnswer, fakeFetch, imagePart, jpegBase64, jpegHeaderBytes, pngBase64, pngHeaderBytes, sseJSON } from "./helpers";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

const userText = (text: string) => ({ role: "user", parts: [{ text }] });
const modelText = (text: string) => ({ role: "model", parts: [{ text }] });

describe("groqProvider", () => {
  it("uses the default models and the free plan's token budget", () => {
    const groq = groqProvider("key");
    expect(groq.name).toBe("groq");
    expect(groq.textModels).toEqual(DEFAULT_GROQ_TEXT_MODELS.split(","));
    expect(groq.visionModels).toEqual(DEFAULT_GROQ_VISION_MODELS.split(","));
    expect(groq.maximumTokens).toBe(7000);
    expect(groq.maximumImages).toBe(3);
  });

  it("takes model lists and a token budget from settings", () => {
    const groq = groqProvider("key", " a , b ,", "v", "50000");
    expect(groq.textModels).toEqual(["a", "b"]);
    expect(groq.visionModels).toEqual(["v"]);
    expect(groq.maximumTokens).toBe(50000);
  });

  it.each(["", "abc", "0", "-5"])("falls back to 7000 tokens for the setting %j", (setting) => {
    expect(groqProvider("key", undefined, undefined, setting).maximumTokens).toBe(7000);
  });

  it("turns thinking down per model family", () => {
    const groq = groqProvider("key");
    expect(groq.extrasForModel("openai/gpt-oss-120b")).toEqual({ reasoning_effort: "low", include_reasoning: false });
    expect(groq.extrasForModel("qwen/qwen3.8-27b")).toEqual({ reasoning_effort: "none", include_reasoning: false });
    expect(groq.extrasForModel("something/else")).toEqual({});
  });
});

describe("nimProvider", () => {
  it("uses the same models for text and pictures", () => {
    const nim = nimProvider("key");
    expect(nim.name).toBe("nim");
    expect(nim.textModels).toEqual(DEFAULT_NIM_MODELS.split(","));
    expect(nim.visionModels).toEqual(nim.textModels);
    expect(nim.maximumImages).toBe(8);
  });

  it("takes its models from settings and turns thinking off", () => {
    const nim = nimProvider("key", "one,two");
    expect(nim.textModels).toEqual(["one", "two"]);
    expect(nim.extrasForModel("one")).toEqual({ chat_template_kwargs: { enable_thinking: false, thinking: false } });
  });
});

describe("imageCount", () => {
  it("is 0 without contents", () => {
    expect(imageCount({})).toBe(0);
  });

  it("counts pictures across turns and ignores other parts", () => {
    const body = {
      contents: [
        { role: "user", parts: [{ text: "look" }, imagePart("AAAA"), imagePart("BBBB", "image/jpeg")] },
        { role: "user", parts: [{ inlineData: { mimeType: "audio/wav", data: "CCCC" } }, imagePart("DDDD")] },
        { role: "model" },
      ],
    };
    expect(imageCount(body)).toBe(3);
  });
});

describe("estimatedTokens", () => {
  it("counts only the answer for an empty body", () => {
    // '""' for the missing system instruction and tools: 4 characters, 1 token.
    expect(estimatedTokens({})).toBe(1 + 1024);
  });

  it("counts text at four characters a token", () => {
    const body = { contents: [userText("a".repeat(400))], generationConfig: { maxOutputTokens: 100 } };
    expect(estimatedTokens(body)).toBe(Math.ceil((400 + 4) / 4) + 100);
  });

  it("counts each picture as 1100 tokens", () => {
    const withPictures = { contents: [{ role: "user", parts: [imagePart("AAAA"), imagePart("BBBB")] }] };
    expect(estimatedTokens(withPictures) - estimatedTokens({})).toBe(2200);
  });

  it("counts tool calls, tool results, the system instruction and the tools", () => {
    const plain = estimatedTokens({ contents: [] });
    const withEverything = estimatedTokens({
      contents: [
        { role: "model", parts: [{ functionCall: { name: "click", args: { target: "x".repeat(200) } } }] },
        { role: "user", parts: [{ functionResponse: { name: "click", response: { result: "y".repeat(200) } } }] },
      ],
      systemInstruction: { parts: [{ text: "z".repeat(200) }] },
      tools: [{ functionDeclarations: [{ name: "click", description: "w".repeat(200) }] }],
    });
    expect(withEverything - plain).toBeGreaterThan(200);
  });

  it("ignores an answer size that isn't a number", () => {
    expect(estimatedTokens({ generationConfig: { maxOutputTokens: "lots" } })).toBe(1 + 1024);
  });
});

describe("canAnswer", () => {
  const groq = groqProvider("key");

  it("takes a small text request", () => {
    expect(canAnswer(groq, { contents: [userText("hello")] })).toBe(true);
  });

  it("turns down a request that wants audio back", () => {
    expect(canAnswer(groq, { contents: [userText("say hi")], generationConfig: { responseModalities: ["audio"] } })).toBe(false);
  });

  it("turns down a request that sends audio or any file that isn't a picture", () => {
    expect(canAnswer(groq, { contents: [{ role: "user", parts: [{ inlineData: { mimeType: "audio/wav", data: "AAAA" } }] }] })).toBe(false);
    expect(canAnswer(groq, { contents: [{ role: "user", parts: [{ inlineData: { data: "AAAA" } }] }] })).toBe(false);
  });

  it("turns down more pictures than the provider takes", () => {
    const fourPictures = { contents: [{ role: "user", parts: [imagePart("A"), imagePart("B"), imagePart("C"), imagePart("D")] }] };
    expect(canAnswer(groq, fourPictures)).toBe(false);
    expect(canAnswer(nimProvider("key"), fourPictures)).toBe(true);
  });

  it("turns down a request over the token budget, and takes one exactly on it", () => {
    const overBudget = { contents: [userText("a".repeat(4 * 7000))] };
    expect(canAnswer(groq, overBudget)).toBe(false);
    const exactlyOnBudget = { contents: [userText("a".repeat(4 * (7000 - 1024) - 4))] };
    expect(estimatedTokens(exactlyOnBudget)).toBe(7000);
    expect(canAnswer(groq, exactlyOnBudget)).toBe(true);
  });
});

describe("fittedForProvider", () => {
  const groq = groqProvider("key");

  it("keeps only the newest pictures and notes the older ones", () => {
    const body = {
      contents: [
        { role: "user", parts: [{ text: "task" }, imagePart("ONE")] },
        { role: "user", parts: [imagePart("TWO"), imagePart("THREE")] },
        { role: "user", parts: [imagePart("FOUR")] },
      ],
    };
    const fitted = fittedForProvider(groq, body, false) as { contents: { parts: any[] }[] };
    expect(fitted.contents[0].parts[1]).toEqual({ text: "(an earlier screenshot, left out)" });
    expect(fitted.contents[1].parts.map((part) => part.inlineData?.data)).toEqual(["TWO", "THREE"]);
    expect(fitted.contents[2].parts[0].inlineData.data).toBe("FOUR");
  });

  it("leaves the original body as it was", () => {
    const body = { contents: [{ role: "user", parts: [imagePart("1"), imagePart("2"), imagePart("3"), imagePart("4")] }] };
    const copyBefore = structuredClone(body);
    fittedForProvider(groq, body, true);
    expect(body).toEqual(copyBefore);
  });

  it("keeps every step when old steps aren't to be dropped", () => {
    const longStep = "s".repeat(8000);
    const body = { contents: [userText("task"), ...Array.from({ length: 10 }, (_, index) => (index % 2 === 0 ? modelText(longStep) : userText(longStep)))] };
    const fitted = fittedForProvider(groq, body, false) as { contents: unknown[] };
    expect(fitted.contents).toHaveLength(11);
  });

  it("drops the oldest steps until it fits, keeping the task and the newest turns", () => {
    const longStep = "s".repeat(6000);
    const steps = Array.from({ length: 12 }, (_, index) => (index % 2 === 0 ? modelText(`${index}${longStep}`) : userText(`${index}${longStep}`)));
    const body = { contents: [userText("the task"), ...steps] };
    const fitted = fittedForProvider(groq, body, true) as { contents: { role: string; parts: { text: string }[] }[] };
    expect(fitted.contents[0].parts[0].text).toBe("the task");
    expect(fitted.contents[1].parts[0].text).toMatch(/^\(\d+ earlier steps left out to keep this short\)$/);
    expect(fitted.contents[1].role).toBe("user");
    // The note is followed by a model turn, so calls keep their results.
    expect(fitted.contents[2].role).toBe("model");
    expect(fitted.contents.at(-1)!.parts[0].text.startsWith("11")).toBe(true);
    expect(fitted.contents.length).toBeLessThan(body.contents.length);
  });

  it("drops a model turn together with the tool results after it", () => {
    const longStep = "s".repeat(9000);
    const body = {
      contents: [
        userText("task"),
        { role: "model", parts: [{ functionCall: { name: "click", args: {} } }] },
        { role: "user", parts: [{ functionResponse: { name: "click", response: { ok: true } } }] },
        modelText(longStep),
        userText(longStep),
        modelText("m1"),
        userText("u1"),
        modelText("m2"),
        userText("u2"),
      ],
    };
    const fitted = fittedForProvider(groq, body, true) as { contents: { role: string; parts: any[] }[] };
    const hasOrphanResult = fitted.contents.some((content, index) => content.parts?.[0]?.functionResponse && fitted.contents[index - 1]?.role !== "model");
    expect(hasOrphanResult).toBe(false);
  });

  it("stops at the task and the four newest turns even when still too big", () => {
    const hugeStep = "s".repeat(40_000);
    const body = { contents: [userText("task"), modelText(hugeStep), userText(hugeStep), modelText(hugeStep), userText(hugeStep), modelText(hugeStep), userText(hugeStep)] };
    const fitted = fittedForProvider(groq, body, true) as { contents: unknown[] };
    expect(fitted.contents.length).toBeGreaterThanOrEqual(5);
    expect(canAnswer(groq, fitted as Record<string, unknown>)).toBe(false);
  });

  it("handles a body without contents", () => {
    expect(fittedForProvider(groq, {}, true)).toEqual({ contents: [] });
  });
});

describe("lowercaseSchema", () => {
  it("lowercases types at every depth and drops Gemini-only keys", () => {
    const schema = {
      type: "OBJECT",
      nullable: true,
      propertyOrdering: ["a"],
      properties: { a: { type: "ARRAY", items: { type: "STRING", enum: ["X"] } } },
      required: ["a"],
    };
    expect(lowercaseSchema(schema)).toEqual({
      type: "object",
      properties: { a: { type: "array", items: { type: "string", enum: ["X"] } } },
      required: ["a"],
    });
  });

  it("leaves a property that happens to be called type alone when it's an object", () => {
    expect(lowercaseSchema({ properties: { type: { type: "STRING" } } })).toEqual({ properties: { type: { type: "string" } } });
  });

  it.each([null, undefined, 5, "TEXT"])("returns %j as it is", (value) => {
    expect(lowercaseSchema(value)).toBe(value);
  });
});

describe("toChatRequest", () => {
  it("turns the system instruction and turns into messages", () => {
    const chatRequest = toChatRequest({
      systemInstruction: { parts: [{ text: "Be brief." }, { text: "hidden", thought: true }] },
      contents: [userText("hi"), modelText("hello"), userText("bye")],
    });
    expect(chatRequest.messages).toEqual([
      { role: "system", content: "Be brief." },
      { role: "user", content: "hi" },
      { role: "assistant", content: "hello" },
      { role: "user", content: "bye" },
    ]);
    expect(chatRequest.tools).toBeUndefined();
  });

  it("has no system message when there is no instruction", () => {
    expect(toChatRequest({ contents: [userText("hi")] }).messages).toEqual([{ role: "user", content: "hi" }]);
  });

  it("puts a response schema into the instructions", () => {
    const withInstruction = toChatRequest({
      systemInstruction: { parts: [{ text: "Be brief." }] },
      generationConfig: { responseSchema: { type: "OBJECT" }, responseMimeType: "application/json" },
    });
    const systemMessage = (withInstruction.messages as { content: string }[])[0].content;
    expect(systemMessage).toContain("Be brief.\n\nReply with only a JSON object matching this JSON schema:");
    expect(systemMessage).toContain('{"type":"object"}');
    expect(withInstruction.response_format).toEqual({ type: "json_object" });

    const schemaOnly = toChatRequest({ generationConfig: { responseSchema: { type: "OBJECT" } } });
    expect((schemaOnly.messages as { content: string }[])[0].content.startsWith("Reply with only a JSON object")).toBe(true);
    expect(schemaOnly.response_format).toBeUndefined();
  });

  it("sends pictures as data addresses and text-only turns as plain strings", () => {
    const chatRequest = toChatRequest({ contents: [{ role: "user", parts: [{ text: "what is this" }, imagePart("AAAA", "image/jpeg")] }] });
    expect(chatRequest.messages).toEqual([
      {
        role: "user",
        content: [
          { type: "text", text: "what is this" },
          { type: "image_url", image_url: { url: "data:image/jpeg;base64,AAAA" } },
        ],
      },
    ]);
  });

  it("skips thoughts, empty text and turns with nothing to send", () => {
    const chatRequest = toChatRequest({
      contents: [
        { role: "user", parts: [{ text: "thinking", thought: true }, { text: "" }] },
        { role: "model", parts: [] },
        { role: "user" },
      ],
    });
    expect(chatRequest.messages).toEqual([]);
  });

  it("gives calls ids and matches results to them by name, in order", () => {
    const chatRequest = toChatRequest({
      contents: [
        {
          role: "model",
          parts: [
            { text: "clicking" },
            { functionCall: { name: "click", args: { x: 1 } } },
            { functionCall: { name: "click", args: { x: 2 } } },
            { functionCall: { name: "type", id: "given-id" } },
          ],
        },
        {
          role: "user",
          parts: [
            { functionResponse: { name: "click", response: { ok: 1 } } },
            { functionResponse: { name: "click", response: { ok: 2 } } },
            { functionResponse: { name: "type", id: "given-id" } },
            { text: "and now?" },
          ],
        },
      ],
    });
    const messages = chatRequest.messages as any[];
    expect(messages[0]).toEqual({
      role: "assistant",
      content: "clicking",
      tool_calls: [
        { id: "call_1", type: "function", function: { name: "click", arguments: '{"x":1}' } },
        { id: "call_2", type: "function", function: { name: "click", arguments: '{"x":2}' } },
        { id: "given-id", type: "function", function: { name: "type", arguments: "{}" } },
      ],
    });
    expect(messages.slice(1, 4)).toEqual([
      { role: "tool", tool_call_id: "call_1", content: '{"ok":1}' },
      { role: "tool", tool_call_id: "call_2", content: '{"ok":2}' },
      { role: "tool", tool_call_id: "given-id", content: "{}" },
    ]);
    expect(messages[4]).toEqual({ role: "user", content: "and now?" });
  });

  it("gives a result with no call before it a fresh id, and a call with no text null content", () => {
    const chatRequest = toChatRequest({
      contents: [
        { role: "user", parts: [{ functionResponse: { name: "orphan", response: 1 } }] },
        { role: "model", parts: [{ functionCall: { name: "click" } }] },
      ],
    });
    const messages = chatRequest.messages as any[];
    expect(messages[0]).toEqual({ role: "tool", tool_call_id: "call_1", content: "1" });
    expect(messages[1].content).toBeNull();
    expect(messages[1].tool_calls[0].id).toBe("call_2");
  });

  it("converts tool declarations and the calling mode", () => {
    const tools = [
      {
        functionDeclarations: [
          { name: "click", description: "Clicks.", parameters: { type: "OBJECT", properties: { x: { type: "NUMBER" } } } },
          { name: "wait", parametersJsonSchema: { type: "object" } },
          { name: "stop" },
        ],
      },
      {},
    ];
    const chatRequest = toChatRequest({ tools });
    expect(chatRequest.tools).toEqual([
      { type: "function", function: { name: "click", description: "Clicks.", parameters: { type: "object", properties: { x: { type: "number" } } } } },
      { type: "function", function: { name: "wait", description: "", parameters: { type: "object" } } },
      { type: "function", function: { name: "stop", description: "", parameters: { type: "object", properties: {} } } },
    ]);
    expect(chatRequest.tool_choice).toBe("auto");
    expect(toChatRequest({ tools, toolConfig: { functionCallingConfig: { mode: "any" } } }).tool_choice).toBe("required");
    expect(toChatRequest({ tools, toolConfig: { functionCallingConfig: { mode: "NONE" } } }).tool_choice).toBe("none");
  });

  it("carries temperature and the answer size over", () => {
    const chatRequest = toChatRequest({ generationConfig: { temperature: 0, maxOutputTokens: 300 } });
    expect(chatRequest.temperature).toBe(0);
    expect(chatRequest.max_tokens).toBe(300);
    const without = toChatRequest({ generationConfig: { temperature: "warm" } });
    expect(without.temperature).toBeUndefined();
    expect(without.max_tokens).toBeUndefined();
  });
});

describe("toGeminiResponse", () => {
  it("turns text into a Gemini answer with usage and the answering model", () => {
    const geminiResponse = toGeminiResponse(
      { choices: [{ message: { content: "  hello  " }, finish_reason: "stop" }], usage: { prompt_tokens: 3, completion_tokens: 4, total_tokens: 7 } },
      "groq/model"
    );
    expect(geminiResponse).toEqual({
      candidates: [{ content: { role: "model", parts: [{ text: "hello" }] }, finishReason: "STOP", index: 0 }],
      usageMetadata: { promptTokenCount: 3, candidatesTokenCount: 4, totalTokenCount: 7 },
      modelVersion: "groq/model",
    });
  });

  it("says MAX_TOKENS when the answer was cut off, and 0 usage when none is given", () => {
    const geminiResponse = toGeminiResponse({ choices: [{ message: { content: "cut" }, finish_reason: "length" }] }, "m") as any;
    expect(geminiResponse.candidates[0].finishReason).toBe("MAX_TOKENS");
    expect(geminiResponse.usageMetadata).toEqual({ promptTokenCount: 0, candidatesTokenCount: 0, totalTokenCount: 0 });
  });

  it("removes GLM's box markers", () => {
    const geminiResponse = toGeminiResponse({ choices: [{ message: { content: "<|begin_of_box|>[1,2]<|end_of_box|>" } }] }, "m") as any;
    expect(geminiResponse.candidates[0].content.parts[0].text).toBe("[1,2]");
  });

  it("turns tool calls into function calls with the placeholder signature", () => {
    const geminiResponse = toGeminiResponse(
      {
        choices: [
          {
            message: {
              content: null,
              tool_calls: [
                { id: "abc", function: { name: "click", arguments: '{"x":1}' } },
                { function: { name: "wait", arguments: { seconds: 2 } } },
                { function: { name: "broken", arguments: "{not json" } },
                { function: { name: "empty", arguments: "" } },
                { function: { name: "null", arguments: "null" } },
                { function: { name: "list", arguments: "[1]" } },
                { function: { arguments: "{}" } },
              ],
            },
          },
        ],
      },
      "m"
    ) as any;
    expect(geminiResponse.candidates[0].content.parts).toEqual([
      { functionCall: { name: "click", args: { x: 1 }, id: "abc" }, thoughtSignature: "skip_thought_signature_validator" },
      { functionCall: { name: "wait", args: { seconds: 2 } }, thoughtSignature: "skip_thought_signature_validator" },
      { functionCall: { name: "broken", args: {} }, thoughtSignature: "skip_thought_signature_validator" },
      { functionCall: { name: "empty", args: {} }, thoughtSignature: "skip_thought_signature_validator" },
      { functionCall: { name: "null", args: {} }, thoughtSignature: "skip_thought_signature_validator" },
      { functionCall: { name: "list", args: {} }, thoughtSignature: "skip_thought_signature_validator" },
    ]);
  });

  it.each([{}, { choices: [] }, { choices: [{ message: { content: "   " } }] }, { choices: [{ message: { content: 5 } }] }])(
    "is undefined when there is nothing to say: %j",
    (chatResponse) => {
      expect(toGeminiResponse(chatResponse, "m")).toBeUndefined();
    }
  );
});

describe("pictureSize", () => {
  it("reads a PNG's size", () => {
    expect(pictureSize(new Uint8Array(pngHeaderBytes(1280, 720)))).toEqual({ width: 1280, height: 720 });
  });

  it("reads a JPEG's size past other segments", () => {
    expect(pictureSize(new Uint8Array(jpegHeaderBytes(1920, 1080)))).toEqual({ width: 1920, height: 1080 });
  });

  it("skips fill bytes, restart markers and stray bytes in a JPEG", () => {
    const bytes = [0xff, 0xd8, 0x00, 0xff, 0xff, 0xd0, 0xff, 0x01, 0xff, 0xc2, 0x00, 0x0b, 0x08, 0x00, 0x64, 0x00, 0xc8, 0x03, 0, 0, 0, 0, 0, 0];
    expect(pictureSize(new Uint8Array(bytes))).toEqual({ width: 200, height: 100 });
  });

  it("doesn't take a Huffman table (0xC4) for the frame", () => {
    const bytes = [0xff, 0xd8, 0xff, 0xc4, 0x00, 0x04, 0x11, 0x22, ...jpegHeaderBytes(640, 480).slice(8)];
    expect(pictureSize(new Uint8Array(bytes))).toEqual({ width: 640, height: 480 });
  });

  it("is undefined for a size of 0", () => {
    expect(pictureSize(new Uint8Array(pngHeaderBytes(0, 720)))).toBeUndefined();
    expect(pictureSize(new Uint8Array(pngHeaderBytes(1280, 0)))).toBeUndefined();
    expect(pictureSize(new Uint8Array(jpegHeaderBytes(0, 0)))).toBeUndefined();
  });

  it("is undefined for too few bytes, another format, or a JPEG with no frame", () => {
    expect(pictureSize(new Uint8Array([]))).toBeUndefined();
    expect(pictureSize(new Uint8Array([0x89, 0x50, 0x4e, 0x47]))).toBeUndefined();
    expect(pictureSize(new Uint8Array([0x47, 0x49, 0x46, 0x38, 0, 0, 0, 0]))).toBeUndefined();
    expect(pictureSize(new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0, 0, 0, 0, 0, 0, 0, 0]))).toBeUndefined();
  });
});

describe("pixelBoxConversion", () => {
  const bodyWithBoxes = (picture = pngBase64(2000, 1000)) => ({
    systemInstruction: { parts: [{ text: "Answer with box_2d as [ymin, xmin, ymax, xmax] from 0 to 1000." }] },
    contents: [
      { role: "user", parts: [{ text: "Find the button. Give target_box_2d." }, imagePart(picture)] },
      { role: "model", parts: [{ functionCall: { name: "click", args: { target_box_2d: [100, 200, 300, 400], note: "box_2d here" } } }] },
    ],
    tools: [
      {
        functionDeclarations: [
          {
            name: "click",
            description: "Click target_box_2d.",
            parameters: { type: "OBJECT", properties: { target_box_2d: { type: "ARRAY" }, target_box: { type: "ARRAY" } }, required: ["target_box_2d"] },
          },
        ],
      },
    ],
    generationConfig: { responseSchema: { type: "OBJECT", properties: { box_2d: { type: "ARRAY" } }, required: ["box_2d"] } },
  });

  it("does nothing when the body never mentions boxes", () => {
    expect(pixelBoxConversion({ contents: [{ role: "user", parts: [{ text: "hello" }, imagePart(pngBase64(10, 10))] }] })).toBeUndefined();
  });

  it("does nothing without a picture, or with one whose size can't be read", () => {
    expect(pixelBoxConversion({ contents: [userText("give box_2d")] })).toBeUndefined();
    expect(pixelBoxConversion({ contents: [{ role: "user", parts: [{ text: "give box_2d" }, imagePart("AAAAAAAA")] }] })).toBeUndefined();
    expect(pixelBoxConversion({ contents: [{ role: "user", parts: [{ text: "give box_2d" }, imagePart("!!not base64!!")] }] })).toBeUndefined();
  });

  it("renames keys in text, schemas and tools, and turns earlier boxes into pixels", () => {
    const conversion = pixelBoxConversion(bodyWithBoxes())!;
    const body = conversion.bodyForProvider as any;
    expect(body.contents[0].parts[0].text).toBe("Find the button. Give target_box_px.");
    // [ymin 100, xmin 200, ymax 300, xmax 400] of 1000 on 2000×1000 → [left 400, top 100, right 800, bottom 300].
    expect(body.contents[1].parts[0].functionCall.args).toEqual({ target_box_px: [400, 100, 800, 300], note: "box_2d here" });
    const declaration = body.tools[0].functionDeclarations[0];
    expect(declaration.description).toBe("Click target_box_px.");
    expect(Object.keys(declaration.parameters.properties)).toEqual(["target_box_px", "target_box_px"].filter((key, index, all) => all.indexOf(key) === index));
    expect(declaration.parameters.required).toEqual(["target_box_px"]);
    expect(body.generationConfig.responseSchema.properties).toEqual({ box_px: { type: "ARRAY" } });
    expect(body.generationConfig.responseSchema.required).toEqual(["box_px"]);
    const systemTexts = body.systemInstruction.parts.map((part: { text: string }) => part.text);
    expect(systemTexts[0]).toBe("Answer with box_px as [left, top, right, bottom] from 0 to 1000.");
    expect(systemTexts[1]).toContain("2000×1000 pixels");
    expect(systemTexts[1]).toContain("[left, top, right, bottom]");
  });

  it("leaves the original body untouched", () => {
    const body = bodyWithBoxes();
    const copyBefore = structuredClone(body);
    pixelBoxConversion(body);
    expect(body).toEqual(copyBefore);
  });

  it("uses the newest picture's size", () => {
    const body = {
      contents: [
        { role: "user", parts: [{ text: "box_2d" }, imagePart(pngBase64(100, 100))] },
        { role: "user", parts: [imagePart(jpegBase64(800, 600), "image/jpeg")] },
      ],
    };
    const systemText = (pixelBoxConversion(body)!.bodyForProvider as any).systemInstruction.parts.at(-1).text;
    expect(systemText).toContain("800×600 pixels");
    expect(systemText).toContain("(box_px)");
  });

  it("turns pixel boxes in an answer's tool calls back into Gemini's keys and 0-1000 boxes", () => {
    const conversion = pixelBoxConversion(bodyWithBoxes())!;
    const answer = conversion.responseForGemini({
      candidates: [
        { content: { parts: [{ functionCall: { name: "click", args: { target_box_px: [400, 100, 800, 300], nested: [{ box_px: [0, 0, 2000, 1000] }], label: "ok" } } }] } },
      ],
    }) as any;
    expect(answer.candidates[0].content.parts[0].functionCall.args).toEqual({
      target_box_2d: [100, 200, 300, 400],
      nested: [{ box_2d: [0, 0, 1000, 1000] }],
      label: "ok",
    });
  });

  it("sorts a box given corner-last, and keeps boxes inside 0 to 1000", () => {
    const conversion = pixelBoxConversion(bodyWithBoxes())!;
    const answer = conversion.responseForGemini({
      candidates: [{ content: { parts: [{ functionCall: { name: "click", args: { target_box_px: [800, 300, 400, 100], other_box_px: [-50, -50, 9000, 9000] } } }] } }],
    }) as any;
    expect(answer.candidates[0].content.parts[0].functionCall.args.target_box_2d).toEqual([100, 200, 300, 400]);
    expect(answer.candidates[0].content.parts[0].functionCall.args.other_box_2d).toEqual([0, 0, 1000, 1000]);
  });

  it("leaves a value that isn't a four-number box as it is", () => {
    const conversion = pixelBoxConversion(bodyWithBoxes())!;
    const answer = conversion.responseForGemini({
      candidates: [{ content: { parts: [{ functionCall: { name: "click", args: { target_box_px: "none", box_px: [1, 2, 3] } } }] } }],
    }) as any;
    expect(answer.candidates[0].content.parts[0].functionCall.args).toEqual({ target_box_2d: "none", box_2d: [1, 2, 3] });
  });

  it("turns pixel boxes written in an answer's text back too", () => {
    const conversion = pixelBoxConversion(bodyWithBoxes())!;
    const answer = conversion.responseForGemini({
      candidates: [{ content: { parts: [{ text: '{"target_box_px": [400, 100, 800, 300], "label": "Sign in"}' }] } }, {}],
    }) as any;
    expect(JSON.parse(answer.candidates[0].content.parts[0].text)).toEqual({ target_box_2d: [100, 200, 300, 400], label: "Sign in" });
  });

  it("handles a body with target_box and no system instruction", () => {
    const conversion = pixelBoxConversion({
      contents: [{ role: "user", parts: [{ text: 'Answer {"target_box": [..]}' }, imagePart(pngBase64(1000, 1000))] }],
      generationConfig: { responseSchema: { type: "OBJECT", properties: { target_box: { type: "ARRAY" } } } },
    })!;
    const body = conversion.bodyForProvider as any;
    expect(body.contents[0].parts[0].text).toBe('Answer {"target_box_px": [..]}');
    expect(body.systemInstruction.parts).toHaveLength(1);
    const answer = conversion.responseForGemini({ candidates: [{ content: { parts: [{ text: '{"target_box_px":[10,20,30,40]}' }] } }] }) as any;
    expect(JSON.parse(answer.candidates[0].content.parts[0].text)).toEqual({ target_box: [20, 10, 40, 30] });
  });
});

describe("textWithGeminiBoxes", () => {
  const doubled = (box: unknown) => (box as number[]).map((value) => value * 2);
  const geminiKey = (key: string) => (key === "box_px" ? "box_2d" : undefined);

  it("converts a bracketed box and one written without brackets", () => {
    expect(textWithGeminiBoxes('"box_px": [1, 2, 3, 4]', doubled, geminiKey)).toBe('"box_2d": [2,4,6,8]');
    expect(textWithGeminiBoxes('"box_px": 1.5, 2, 3, 4', doubled, geminiKey)).toBe('"box_2d": [3,4,6,8]');
  });

  it("renames a key whose value isn't a box, and keeps a key it doesn't know", () => {
    expect(textWithGeminiBoxes('"box_px": null', doubled, geminiKey)).toBe('"box_2d": null');
    expect(textWithGeminiBoxes('"mystery_box_px": [1, 2, 3, 4]', doubled, geminiKey)).toBe('"mystery_box_px": [2,4,6,8]');
  });

  it("leaves other text alone", () => {
    expect(textWithGeminiBoxes("no boxes here", doubled, geminiKey)).toBe("no boxes here");
  });
});

describe("answerWithProvider", () => {
  const groq = groqProvider("groq-key", "text-one,text-two", "vision-one");

  it("asks the first text model and answers in Gemini's shape", async () => {
    const calls = fakeFetch([["api.groq.com", chatAnswer({ content: "hello" })]]);
    const response = await answerWithProvider(groq, { contents: [userText("hi")] }, false);
    expect(response!.headers.get("content-type")).toBe("application/json");
    const geminiResponse = (await response!.json()) as any;
    expect(geminiResponse.candidates[0].content.parts[0].text).toBe("hello");
    expect(geminiResponse.modelVersion).toBe("groq/text-one");
    expect(calls).toHaveLength(1);
    expect(calls[0].headers.get("authorization")).toBe("Bearer groq-key");
    expect(calls[0].json).toMatchObject({ model: "text-one", stream: false, max_tokens: 1024 });
  });

  it("keeps the answer size the request asked for", async () => {
    const calls = fakeFetch([["api.groq.com", chatAnswer({ content: "hello" })]]);
    await answerWithProvider(groq, { contents: [userText("hi")], generationConfig: { maxOutputTokens: 50 } }, false);
    expect(calls[0].json.max_tokens).toBe(50);
  });

  it("answers as one server-sent event when streaming", async () => {
    fakeFetch([["api.groq.com", chatAnswer({ content: "hello" })]]);
    const response = await answerWithProvider(groq, { contents: [userText("hi")] }, true);
    expect(response!.headers.get("content-type")).toBe("text/event-stream");
    const text = await response!.clone().text();
    expect(text.startsWith("data: ")).toBe(true);
    expect(text.endsWith("\r\n\r\n")).toBe(true);
    expect((await sseJSON(response!)).candidates[0].content.parts[0].text).toBe("hello");
  });

  it("uses the vision models when the request has a picture", async () => {
    const calls = fakeFetch([["api.groq.com", chatAnswer({ content: "a cat" })]]);
    await answerWithProvider(groq, { contents: [{ role: "user", parts: [{ text: "what" }, imagePart("AAAA")] }] }, false);
    expect(calls[0].json.model).toBe("vision-one");
  });

  it("tries again without the model's extras after a 400, then answers", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const gptOss = groqProvider("key", "openai/gpt-oss-120b");
    const calls = fakeFetch([
      ["api.groq.com", (call) => (call.json.reasoning_effort ? new Response("unknown field", { status: 400 }) : chatAnswer({ content: "plain" }))],
    ]);
    const response = await answerWithProvider(gptOss, { contents: [userText("hi")] }, false);
    expect(((await response!.json()) as any).candidates[0].content.parts[0].text).toBe("plain");
    expect(calls).toHaveLength(2);
    expect(calls[0].json.reasoning_effort).toBe("low");
    expect(calls[1].json.reasoning_effort).toBeUndefined();
  });

  it("moves to the next model after a busy answer, without a second try on the busy one", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const calls = fakeFetch([
      ["api.groq.com", (call) => (call.json.model === "text-one" ? new Response("slow down", { status: 429 }) : chatAnswer({ content: "from two" }))],
    ]);
    const response = await answerWithProvider(groq, { contents: [userText("hi")] }, false);
    expect(((await response!.json()) as any).modelVersion).toBe("groq/text-two");
    expect(calls.map((call) => call.json.model)).toEqual(["text-one", "text-two"]);
  });

  it("moves to the next model when one gives an empty answer", async () => {
    const calls = fakeFetch([
      ["api.groq.com", (call) => (call.json.model === "text-one" ? chatAnswer({ content: "" }) : chatAnswer({ content: "from two" }))],
    ]);
    const response = await answerWithProvider(groq, { contents: [userText("hi")] }, false);
    expect(((await response!.json()) as any).modelVersion).toBe("groq/text-two");
    expect(calls).toHaveLength(2);
  });

  it("is undefined when every model fails", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const calls = fakeFetch([["api.groq.com", new Response("down", { status: 503 })]]);
    expect(await answerWithProvider(groq, { contents: [userText("hi")] }, false)).toBeUndefined();
    expect(calls).toHaveLength(2);
  });

  it("moves on when a model can't be reached or answers something that isn't JSON", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const calls = fakeFetch([
      [
        "api.groq.com",
        (call) => {
          if (call.json.model === "text-one") throw new TypeError("connection lost");
          return new Response("<html>gateway</html>", { status: 200 });
        },
      ],
    ]);
    expect(await answerWithProvider(groq, { contents: [userText("hi")] }, false)).toBeUndefined();
    expect(calls).toHaveLength(2);
  });

  it("gives each call a time limit", async () => {
    let signal: AbortSignal | null | undefined;
    vi.stubGlobal("fetch", (_input: RequestInfo | URL, init?: RequestInit) => {
      signal = init?.signal;
      return Promise.resolve(chatAnswer({ content: "ok" }));
    });
    await answerWithProvider(groq, { contents: [userText("hi")] }, false);
    expect(signal).toBeInstanceOf(AbortSignal);
  });

  it("asks Groq for pixel boxes and answers with Gemini's", async () => {
    const calls = fakeFetch([["api.groq.com", chatAnswer({ content: '{"box_px": [500, 250, 1000, 500]}' })]]);
    const body = { contents: [{ role: "user", parts: [{ text: 'Reply {"box_2d": [ymin, xmin, ymax, xmax]}' }, imagePart(pngBase64(2000, 1000))] }] };
    const response = await answerWithProvider(groq, body, false);
    expect(calls[0].bodyText).toContain("box_px");
    expect(calls[0].bodyText).not.toContain("box_2d");
    const text = ((await response!.json()) as any).candidates[0].content.parts[0].text;
    expect(JSON.parse(text)).toEqual({ box_2d: [250, 250, 500, 500] });
  });

  it("sends NIM the boxes as Gemini wrote them, with no forced answer size", async () => {
    const calls = fakeFetch([["integrate.api.nvidia.com", chatAnswer({ content: '{"box_2d": [1, 2, 3, 4]}' })]]);
    const body = { contents: [{ role: "user", parts: [{ text: "Reply with box_2d" }, imagePart(pngBase64(2000, 1000))] }] };
    const response = await answerWithProvider(nimProvider("nim-key", "nim-one"), body, false);
    expect(calls[0].bodyText).toContain("box_2d");
    expect(calls[0].json.max_tokens).toBeUndefined();
    expect(calls[0].json.chat_template_kwargs).toEqual({ enable_thinking: false, thinking: false });
    expect(((await response!.json()) as any).modelVersion).toBe("nim/nim-one");
  });
});

describe("salvagedToolUseFailure", () => {
  const failure = (failedGeneration: unknown, code = "tool_use_failed") =>
    JSON.stringify({ error: { code, failed_generation: failedGeneration } });

  it("returns the words the model wrote when no tools were offered", () => {
    expect(salvagedToolUseFailure(failure("  Hi there!  "), {})).toBe("Hi there!");
    expect(salvagedToolUseFailure(failure("REQUEST"), { tools: [] })).toBe("REQUEST");
  });

  it("leaves real tool requests, other errors and junk alone", () => {
    expect(salvagedToolUseFailure(failure("hi"), { tools: [{ type: "function" }] })).toBeUndefined();
    expect(salvagedToolUseFailure(failure("hi", "invalid_request_error"), {})).toBeUndefined();
    expect(salvagedToolUseFailure(failure(42), {})).toBeUndefined();
    expect(salvagedToolUseFailure(failure("   "), {})).toBeUndefined();
    expect(salvagedToolUseFailure("not json", {})).toBeUndefined();
    expect(salvagedToolUseFailure("null", {})).toBeUndefined();
  });
});
