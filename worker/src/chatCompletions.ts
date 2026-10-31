/**
 * Providers that speak OpenAI's chat format: Groq (first choice for quick
 * asks, and a backup) and NVIDIA NIM (last resort). This turns a Gemini
 * generateContent body into a chat request and the answer back into a
 * Gemini response, so the app and Gemini CLI never know the difference.
 *
 * Groq is very fast (well under a second) but its free plan is small per
 * model: about 30 requests and 8,000 tokens a minute, 1,000 requests and
 * 200,000 tokens a day. So only small requests go to it (a few pictures at
 * most, no long histories); screen jobs with many screenshots and the Dots
 * (Gemini CLI, very long prompts) stay on Gemini. NIM's free endpoints are
 * slower (about 40 requests a minute per key), so it's only a backup.
 * Voice (Live), speech and dictation stay on Gemini: neither has those.
 */

export interface ChatProvider {
  /** For logs and the modelVersion the app sees, like "groq". */
  name: string;
  apiURL: string;
  apiKey: string;
  /** Models to try in order for a text-only request. */
  textModels: string[];
  /** Models to try in order when the request has pictures. */
  visionModels: string[];
  /** Most pictures one request may carry; more means not this provider. */
  maximumImages: number;
  /** Rough token budget (prompt + answer) a request must fit in. */
  maximumTokens: number;
  /** Model-specific switches (thinking off); retried without them on a 400. */
  extrasForModel: (model: string) => Record<string, unknown>;
}

const GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions";
const NIM_API_URL = "https://integrate.api.nvidia.com/v1/chat/completions";

/** Groq text models, best first; each has its own free per-minute limit. */
export const DEFAULT_GROQ_TEXT_MODELS = "openai/gpt-oss-120b,openai/gpt-oss-20b,qwen/qwen3.8-27b";
/** Groq's vision model (3 pictures a request, tools and JSON work). */
export const DEFAULT_GROQ_VISION_MODELS = "qwen/qwen3.8-27b";
/** Vision + tool-calling models on NIM's free endpoints, best first. */
export const DEFAULT_NIM_MODELS = "z-ai/glm-5.3-flash,deepseek-ai/deepseek-v4.1-flash";

/** Answers at the end count toward Groq's per-minute tokens too. */
const DEFAULT_ANSWER_TOKENS = 1024;

export function groqProvider(apiKey: string, textModels?: string, visionModels?: string): ChatProvider {
  return {
    name: "groq",
    apiURL: GROQ_API_URL,
    apiKey,
    textModels: modelList(textModels || DEFAULT_GROQ_TEXT_MODELS),
    visionModels: modelList(visionModels || DEFAULT_GROQ_VISION_MODELS),
    maximumImages: 3,
    // The free plan allows 8,000 tokens a minute per model.
    maximumTokens: 7000,
    extrasForModel: (model) => {
      // Thinking costs time and tokens these quick asks don't need.
      if (model.startsWith("openai/gpt-oss")) return { reasoning_effort: "low", include_reasoning: false };
      if (model.startsWith("qwen/")) return { reasoning_effort: "none", include_reasoning: false };
      return {};
    },
  };
}

export function nimProvider(apiKey: string, models?: string): ChatProvider {
  const nimModels = modelList(models || DEFAULT_NIM_MODELS);
  return {
    name: "nim",
    apiURL: NIM_API_URL,
    apiKey,
    textModels: nimModels,
    visionModels: nimModels,
    maximumImages: 8,
    maximumTokens: 100_000,
    extrasForModel: () => ({ chat_template_kwargs: { enable_thinking: false, thinking: false } }),
  };
}

function modelList(commaSeparated: string): string[] {
  return commaSeparated.split(",").map((name) => name.trim()).filter(Boolean);
}

type GeminiPart = {
  text?: string;
  thought?: boolean;
  thoughtSignature?: string;
  inlineData?: { mimeType?: string; data?: string };
  functionCall?: { name?: string; args?: unknown; id?: string };
  functionResponse?: { name?: string; response?: unknown; id?: string };
};

type GeminiContent = { role?: string; parts?: GeminiPart[] };

type ChatMessage = {
  role: "system" | "user" | "assistant" | "tool";
  content: string | Array<Record<string, unknown>> | null;
  tool_calls?: Array<{ id: string; type: "function"; function: { name: string; arguments: string } }>;
  tool_call_id?: string;
};

/**
 * Gemini 3 turns down a function call in the history that has no thought
 * signature. Calls answered by Groq or NIM get this placeholder (the one
 * Gemini documents for calls it didn't make), so a job can move back to
 * Gemini mid-way.
 */
const PLACEHOLDER_THOUGHT_SIGNATURE = "skip_thought_signature_validator";

/** How many pictures a Gemini body carries. */
function imageCount(geminiBody: Record<string, unknown>): number {
  let count = 0;
  for (const content of (geminiBody.contents ?? []) as GeminiContent[]) {
    for (const part of content.parts ?? []) {
      if ((part.inlineData?.mimeType ?? "").startsWith("image/")) count += 1;
    }
  }
  return count;
}

/** True when the body sends or wants audio, which these providers can't do. */
function involvesAudio(geminiBody: Record<string, unknown>): boolean {
  const generationConfig = (geminiBody.generationConfig ?? {}) as Record<string, unknown>;
  const modalities = (generationConfig.responseModalities ?? []) as string[];
  if (modalities.some((modality) => String(modality).toUpperCase() === "AUDIO")) return true;
  for (const content of (geminiBody.contents ?? []) as GeminiContent[]) {
    for (const part of content.parts ?? []) {
      const mimeType = part.inlineData?.mimeType ?? "";
      if (part.inlineData && !mimeType.startsWith("image/")) return true;
    }
  }
  return false;
}

/**
 * A rough token count: text at about four characters a token, pictures at
 * about 1,100 tokens each (Groq counts up to 1,026), plus the answer.
 */
function estimatedTokens(geminiBody: Record<string, unknown>): number {
  let characterCount = 0;
  for (const content of (geminiBody.contents ?? []) as GeminiContent[]) {
    for (const part of content.parts ?? []) {
      if (typeof part.text === "string") characterCount += part.text.length;
      if (part.functionCall) characterCount += JSON.stringify(part.functionCall).length;
      if (part.functionResponse) characterCount += JSON.stringify(part.functionResponse).length;
    }
  }
  characterCount += JSON.stringify(geminiBody.systemInstruction ?? "").length;
  characterCount += JSON.stringify(geminiBody.tools ?? "").length;
  const generationConfig = (geminiBody.generationConfig ?? {}) as Record<string, unknown>;
  const answerTokens = typeof generationConfig.maxOutputTokens === "number" ? generationConfig.maxOutputTokens : DEFAULT_ANSWER_TOKENS;
  return Math.ceil(characterCount / 4) + imageCount(geminiBody) * 1100 + answerTokens;
}

/**
 * True when this provider can answer the body: text and a few pictures,
 * small enough for its limits. Screen pointing answers in Gemini's own
 * box_2d coordinates, which other models write in a different order, so
 * those requests never leave Gemini.
 */
export function canAnswer(provider: ChatProvider, geminiBody: Record<string, unknown>): boolean {
  if (involvesAudio(geminiBody)) return false;
  if (imageCount(geminiBody) > provider.maximumImages) return false;
  if (provider.name !== "nim" && JSON.stringify(geminiBody.contents ?? "").includes("box_2d")) return false;
  if (provider.name !== "nim" && JSON.stringify(geminiBody.systemInstruction ?? "").includes("box_2d")) return false;
  return estimatedTokens(geminiBody) <= provider.maximumTokens;
}

/**
 * Asks the provider's models in turn. Returns a Gemini-shaped response (one
 * SSE event when `streaming`), or undefined when every model failed.
 */
export async function answerWithProvider(
  provider: ChatProvider,
  geminiBody: Record<string, unknown>,
  streaming: boolean
): Promise<Response | undefined> {
  const models = imageCount(geminiBody) > 0 ? provider.visionModels : provider.textModels;
  const chatRequest = toChatRequest(geminiBody);
  if (provider.name === "groq" && typeof chatRequest.max_tokens !== "number") {
    chatRequest.max_tokens = DEFAULT_ANSWER_TOKENS;
  }
  for (const model of models) {
    for (const extras of [provider.extrasForModel(model), {}]) {
      const response = await fetch(provider.apiURL, {
        method: "POST",
        headers: {
          authorization: `Bearer ${provider.apiKey}`,
          "content-type": "application/json",
          accept: "application/json",
        },
        body: JSON.stringify({ ...chatRequest, ...extras, model, stream: false }),
      });
      if (response.ok) {
        const chatResponse = (await response.json()) as Record<string, unknown>;
        const geminiResponse = toGeminiResponse(chatResponse, `${provider.name}/${model}`);
        if (!geminiResponse) break;
        const payload = JSON.stringify(geminiResponse);
        return streaming
          ? new Response(`data: ${payload}\r\n\r\n`, {
              status: 200,
              headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
            })
          : new Response(payload, { status: 200, headers: { "content-type": "application/json" } });
      }
      const errorText = await response.text();
      console.warn(`[${provider.name}] ${model} answered ${response.status}: ${errorText.slice(0, 300)}`);
      // Only a rejected request is worth retrying without the extras.
      if (response.status !== 400 && response.status !== 422) break;
      if (Object.keys(extras).length === 0) break;
    }
  }
  return undefined;
}

// MARK: - Gemini → chat

function toChatRequest(geminiBody: Record<string, unknown>): Record<string, unknown> {
  const messages: ChatMessage[] = [];

  const systemText = partsText(((geminiBody.systemInstruction ?? {}) as GeminiContent).parts);
  if (systemText) messages.push({ role: "system", content: systemText });

  // Gemini matches tool results to calls by name (ids are optional), the
  // chat format by id, so calls get ids here and results look them up.
  const openCallIDsByName = new Map<string, string[]>();
  let callCounter = 0;

  for (const content of (geminiBody.contents ?? []) as GeminiContent[]) {
    const parts = content.parts ?? [];
    if (content.role === "model") {
      const text = partsText(parts);
      const toolCalls = parts
        .filter((part) => part.functionCall?.name)
        .map((part) => {
          const name = part.functionCall!.name!;
          const id = part.functionCall!.id || `call_${++callCounter}`;
          openCallIDsByName.set(name, [...(openCallIDsByName.get(name) ?? []), id]);
          return { id, type: "function" as const, function: { name, arguments: JSON.stringify(part.functionCall!.args ?? {}) } };
        });
      if (text || toolCalls.length) {
        messages.push({ role: "assistant", content: text || null, ...(toolCalls.length ? { tool_calls: toolCalls } : {}) });
      }
      continue;
    }

    // A user turn: tool results first, then what the user sent.
    for (const part of parts) {
      if (!part.functionResponse?.name) continue;
      const name = part.functionResponse.name;
      const waitingIDs = openCallIDsByName.get(name) ?? [];
      const id = part.functionResponse.id || waitingIDs.shift() || `call_${++callCounter}`;
      openCallIDsByName.set(name, waitingIDs.filter((waitingID) => waitingID !== id));
      messages.push({ role: "tool", tool_call_id: id, content: JSON.stringify(part.functionResponse.response ?? {}) });
    }
    const userContent: Array<Record<string, unknown>> = [];
    for (const part of parts) {
      if (part.thought) continue;
      if (typeof part.text === "string" && part.text) {
        userContent.push({ type: "text", text: part.text });
      } else if (part.inlineData?.data && (part.inlineData.mimeType ?? "").startsWith("image/")) {
        userContent.push({ type: "image_url", image_url: { url: `data:${part.inlineData.mimeType};base64,${part.inlineData.data}` } });
      }
    }
    // Text-only turns go as a plain string, which every model takes.
    const isTextOnly = userContent.every((item) => item.type === "text");
    if (userContent.length) {
      messages.push({
        role: "user",
        content: isTextOnly ? userContent.map((item) => String(item.text)).join("\n") : userContent,
      });
    }
  }

  const chatRequest: Record<string, unknown> = { messages };

  const functionDeclarations = ((geminiBody.tools ?? []) as Array<Record<string, unknown>>)
    .flatMap((tool) => (tool.functionDeclarations ?? []) as Array<Record<string, unknown>>);
  if (functionDeclarations.length) {
    chatRequest.tools = functionDeclarations.map((declaration) => ({
      type: "function",
      function: {
        name: declaration.name,
        description: declaration.description ?? "",
        parameters: lowercaseSchema(declaration.parameters ?? declaration.parametersJsonSchema ?? { type: "object", properties: {} }),
      },
    }));
    const mode = String(
      (((geminiBody.toolConfig ?? {}) as Record<string, unknown>).functionCallingConfig as Record<string, unknown> | undefined)?.mode ?? ""
    ).toUpperCase();
    chatRequest.tool_choice = mode === "ANY" ? "required" : mode === "NONE" ? "none" : "auto";
  }

  const generationConfig = (geminiBody.generationConfig ?? {}) as Record<string, unknown>;
  if (typeof generationConfig.temperature === "number") chatRequest.temperature = generationConfig.temperature;
  if (typeof generationConfig.maxOutputTokens === "number") chatRequest.max_tokens = generationConfig.maxOutputTokens;
  if (generationConfig.responseMimeType === "application/json") chatRequest.response_format = { type: "json_object" };

  return chatRequest;
}

function partsText(parts: GeminiPart[] | undefined): string {
  return (parts ?? [])
    .filter((part) => !part.thought && typeof part.text === "string")
    .map((part) => part.text)
    .join("\n")
    .trim();
}

/** Gemini schemas use OBJECT/STRING; JSON Schema wants object/string. */
function lowercaseSchema(schema: unknown): unknown {
  if (Array.isArray(schema)) return schema.map(lowercaseSchema);
  if (!schema || typeof schema !== "object") return schema;
  const converted: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(schema as Record<string, unknown>)) {
    if (key === "type" && typeof value === "string") {
      converted.type = value.toLowerCase();
    } else if (key === "nullable" || key === "propertyOrdering") {
      continue;
    } else {
      converted[key] = lowercaseSchema(value);
    }
  }
  return converted;
}

// MARK: - chat → Gemini

function toGeminiResponse(chatResponse: Record<string, unknown>, answeringModel: string): Record<string, unknown> | undefined {
  const choice = ((chatResponse.choices ?? []) as Array<Record<string, unknown>>)[0];
  const message = (choice?.message ?? {}) as Record<string, unknown>;
  const parts: GeminiPart[] = [];

  // GLM wraps boxes in <|begin_of_box|>…<|end_of_box|>; the app wants the JSON.
  const text = typeof message.content === "string"
    ? message.content.replace(/<\|(begin|end)_of_box\|>/g, "").trim()
    : "";
  if (text) parts.push({ text });

  for (const toolCall of (message.tool_calls ?? []) as Array<Record<string, unknown>>) {
    const call = (toolCall.function ?? {}) as Record<string, unknown>;
    if (typeof call.name !== "string") continue;
    let args: unknown = {};
    try {
      args = typeof call.arguments === "string" && call.arguments ? JSON.parse(call.arguments) : call.arguments ?? {};
    } catch {
      args = {};
    }
    parts.push({
      functionCall: { name: call.name, args, ...(typeof toolCall.id === "string" ? { id: toolCall.id } : {}) },
      thoughtSignature: PLACEHOLDER_THOUGHT_SIGNATURE,
    });
  }
  if (!parts.length) return undefined;

  const finishReason = choice?.finish_reason === "length" ? "MAX_TOKENS" : "STOP";
  const usage = (chatResponse.usage ?? {}) as Record<string, number>;
  return {
    candidates: [{ content: { role: "model", parts }, finishReason, index: 0 }],
    usageMetadata: {
      promptTokenCount: usage.prompt_tokens ?? 0,
      candidatesTokenCount: usage.completion_tokens ?? 0,
      totalTokenCount: usage.total_tokens ?? 0,
    },
    modelVersion: answeringModel,
  };
}
