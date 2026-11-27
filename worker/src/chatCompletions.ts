/**
 * Providers that speak OpenAI's chat format: Groq (first choice for quick
 * asks, and a backup) and NVIDIA NIM (last resort). This turns a Gemini
 * generateContent body into a chat request and the answer back into a
 * Gemini response, so the app and Gemini CLI never know the difference.
 *
 * Groq is very fast (well under a second) but its free plan is small per
 * model: about 30 requests and 8,000 tokens a minute, 1,000 requests and
 * 200,000 tokens a day, and it turns down any one request over the
 * minute's tokens. So a request goes to Groq only when it fits
 * (GROQ_MAX_REQUEST_TOKENS, 7,000 by default; raise it on a paid plan):
 * screen jobs send Groq only their newest screenshots and recent steps
 * (fittedForProvider), and a Dot turn too big for it goes to Gemini.
 * Pointing asks Groq for boxes in pixels and turns them into Gemini's
 * box_2d (pixelBoxes below). NIM's free endpoints are slower (about 40
 * requests a minute per key), so it's only a backup. Voice (Live), speech
 * and dictation stay on Gemini: neither has those.
 */

import { ANTHROPIC_API_URL, ANTHROPIC_VERSION, fromAnthropicResponse, toAnthropicRequest } from "./anthropicMessages";

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
  /**
   * How long one model may take to answer before the next one is tried.
   * Without it a provider that stops answering would hold the request and
   * Gemini would never get its turn.
   */
  attemptTimeoutMilliseconds: number;
  /** Model-specific switches (thinking off); retried without them on a 400. */
  extrasForModel: (model: string) => Record<string, unknown>;
  /**
   * The provider's own server-side tools for this model (Groq's
   * browser_search on GPT-OSS), added after the request's own tools. Like
   * the extras, they are dropped on the retry after a 400.
   */
  builtInToolsForModel?: (model: string) => Array<Record<string, unknown>>;
  /** "anthropic" speaks Claude's Messages API; otherwise OpenAI's chat format. */
  format?: "chat" | "anthropic";
  /** Asked for boxes in pixels of the newest picture (see pixelBoxConversion). */
  usesPixelBoxes?: boolean;
  /**
   * Boxes in the model's own 0-1000 grid, left first ([left, top, right,
   * bottom]), the way GLM's vision models are trained to answer. Gemini's
   * box_2d is top first, so GLM's answers came back with x and y swapped.
   */
  usesThousandGridLeftFirstBoxes?: boolean;
}

const GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions";
const NIM_API_URL = "https://integrate.api.nvidia.com/v1/chat/completions";
const ZAI_API_URL = "https://api.z.ai/api/paas/v4/chat/completions";

/** Claude models for paid asks, best first (Haiku: fast and cheap). */
export const DEFAULT_ANTHROPIC_MODELS = "claude-haiku-5-5";
/** Z.ai's GLM models, best first; GLM-5.3-Flash takes pictures and tools. */
export const DEFAULT_ZAI_MODELS = "glm-5.3-flash";

/** Groq text models, best first; each has its own free per-minute limit. */
export const DEFAULT_GROQ_TEXT_MODELS = "openai/gpt-oss-120b,openai/gpt-oss-20b,qwen/qwen3.8-27b";
/** Groq's vision model (3 pictures a request, tools and JSON work). */
export const DEFAULT_GROQ_VISION_MODELS = "qwen/qwen3.8-27b";
/** Vision + tool-calling models on NIM's free endpoints, best first. */
export const DEFAULT_NIM_MODELS = "z-ai/glm-5.3-flash,deepseek-ai/deepseek-v4.1-flash";

/** Answers at the end count toward Groq's per-minute tokens too. */
const DEFAULT_ANSWER_TOKENS = 1024;

/**
 * Room for a built-in search: the model's reasoning and its search calls
 * count as answer tokens, so a talker's 160 would be used up before the
 * answer. Only the tokens actually written are paid for.
 */
export const MINIMUM_ANSWER_TOKENS_WITH_BUILT_IN_TOOLS = 1024;

/** Groq's own web search, which GPT-OSS runs on Groq's side. */
export const GROQ_BROWSER_SEARCH_TOOL = { type: "browser_search" };

/** Groq's built-in browser search for the GPT-OSS models, none for the others. */
export function groqBrowserSearchTools(model: string): Array<Record<string, unknown>> {
  return model.startsWith("openai/gpt-oss") ? [GROQ_BROWSER_SEARCH_TOOL] : [];
}

/** Groq's free plan allows 8,000 tokens a minute per model. */
const DEFAULT_GROQ_MAX_REQUEST_TOKENS = 7000;

export function groqProvider(apiKey: string, textModels?: string, visionModels?: string, maximumRequestTokens?: string): ChatProvider {
  const configuredMaximumTokens = Number.parseInt(maximumRequestTokens ?? "", 10);
  return {
    name: "groq",
    apiURL: GROQ_API_URL,
    apiKey,
    textModels: modelList(textModels || DEFAULT_GROQ_TEXT_MODELS),
    visionModels: modelList(visionModels || DEFAULT_GROQ_VISION_MODELS),
    maximumImages: 3,
    usesPixelBoxes: true,
    attemptTimeoutMilliseconds: 30_000,
    maximumTokens: Number.isFinite(configuredMaximumTokens) && configuredMaximumTokens > 0
      ? configuredMaximumTokens
      : DEFAULT_GROQ_MAX_REQUEST_TOKENS,
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
    // NIM's free endpoints are slow to start.
    attemptTimeoutMilliseconds: 60_000,
    extrasForModel: () => ({ chat_template_kwargs: { enable_thinking: false, thinking: false } }),
  };
}

/** Claude through Anthropic's Messages API (paid key, ANTHROPIC_API_KEY). */
export function anthropicProvider(apiKey: string, models?: string): ChatProvider {
  const claudeModels = modelList(models || DEFAULT_ANTHROPIC_MODELS);
  return {
    name: "claude",
    apiURL: ANTHROPIC_API_URL,
    apiKey,
    textModels: claudeModels,
    visionModels: claudeModels,
    maximumImages: 6,
    maximumTokens: 150_000,
    attemptTimeoutMilliseconds: 60_000,
    format: "anthropic",
    // Claude measures pictures in pixels, so it gets the same pixel boxes as Groq.
    usesPixelBoxes: true,
    // Quick asks and screen steps don't need thinking time.
    extrasForModel: () => ({ thinking: { type: "disabled" } }),
  };
}

/** GLM through Z.ai's own API (paid key, ZAI_API_KEY). */
export function zaiProvider(apiKey: string, models?: string): ChatProvider {
  const glmModels = modelList(models || DEFAULT_ZAI_MODELS);
  return {
    name: "glm",
    apiURL: ZAI_API_URL,
    apiKey,
    textModels: glmModels,
    visionModels: glmModels,
    maximumImages: 5,
    maximumTokens: 100_000,
    attemptTimeoutMilliseconds: 45_000,
    usesThousandGridLeftFirstBoxes: true,
    extrasForModel: () => ({ thinking: { type: "disabled" } }),
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
export function imageCount(geminiBody: Record<string, unknown>): number {
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
export function estimatedTokens(geminiBody: Record<string, unknown>): number {
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
 * small enough for its limits. Screen pointing (box_2d) goes to Groq in
 * pixels (see pixelBoxes) and to NIM as it is.
 */
export function canAnswer(provider: ChatProvider, geminiBody: Record<string, unknown>): boolean {
  if (involvesAudio(geminiBody)) return false;
  if (imageCount(geminiBody) > provider.maximumImages) return false;
  return estimatedTokens(geminiBody) <= provider.maximumTokens;
}

/**
 * The body cut down to what the provider takes, for jobs that send a
 * screenshot every step: only the newest pictures stay (older ones become
 * a short note), and with `dropOldSteps` the oldest steps between the
 * first message and the last few go until it fits. A model turn and the
 * tool results after it go together, so every call keeps its result.
 * The original body is left as it was for Gemini.
 */
export function fittedForProvider(
  provider: ChatProvider,
  geminiBody: Record<string, unknown>,
  dropOldSteps: boolean
): Record<string, unknown> {
  const contents = structuredClone((geminiBody.contents ?? []) as GeminiContent[]);

  let picturesToKeep = provider.maximumImages;
  for (let contentIndex = contents.length - 1; contentIndex >= 0; contentIndex -= 1) {
    const parts = contents[contentIndex].parts ?? [];
    for (let partIndex = parts.length - 1; partIndex >= 0; partIndex -= 1) {
      if (!(parts[partIndex].inlineData?.mimeType ?? "").startsWith("image/")) continue;
      if (picturesToKeep > 0) {
        picturesToKeep -= 1;
      } else {
        parts[partIndex] = { text: "(an earlier screenshot, left out)" };
      }
    }
  }

  const fittedBody: Record<string, unknown> = { ...geminiBody, contents };
  if (!dropOldSteps) return fittedBody;

  // Keep the first message (the task) and at least the last four turns.
  const newestTurnsToKeep = 4;
  let leftOutStepCount = 0;
  while (estimatedTokens(fittedBody) > provider.maximumTokens && contents.length > 1 + newestTurnsToKeep) {
    // Drop from the second turn on: a model turn with the user turn after it.
    const removeCount = contents[1]?.role === "model" && contents[2]?.role !== "model" ? 2 : 1;
    contents.splice(1, removeCount);
    leftOutStepCount += 1;
    // The history must not start a pair with tool results whose call is gone.
    while (contents.length > 1 + newestTurnsToKeep && contents[1]?.role !== "model") {
      contents.splice(1, 1);
    }
  }
  if (leftOutStepCount > 0) {
    contents.splice(1, 0, { role: "user", parts: [{ text: `(${leftOutStepCount} earlier steps left out to keep this short)` }] });
    // A user note followed by the kept model turn keeps the turns alternating.
  }
  return fittedBody;
}

// MARK: - Usage and cost per answer

type AnswerUsageMetadata = {
  promptTokenCount?: number; candidatesTokenCount?: number;
  /** Claude's prompt cache: input read from it, and input written to it (both inside promptTokenCount). */
  cachedContentTokenCount?: number; cacheWriteTokenCount?: number;
};

/** What reading and writing cached input costs, against the input price (Anthropic's prompt caching). */
export const CACHE_READ_PRICE_SHARE = 0.1;
export const CACHE_WRITE_PRICE_SHARE = 1.25;

/**
 * Dollars per million tokens (input/output) for the models Dottie uses.
 * Claude Haiku 5.5's are Anthropic's list prices; GLM-5.3-Flash's are
 * Z.ai's regular price after its launch discount ended (9 Sep 2026). Groq
 * and NIM aren't listed because their prices weren't checked: set them in
 * MODEL_PRICES ("model=input/output,…") from the providers' consoles, and
 * until then their answers say the cost is unknown instead of $0.
 */
export const DEFAULT_MODEL_PRICES = "claude-haiku-5-5=0.10/0.50,glm-5.3-flash=0.15/0.50";

export interface ModelPrice {
  inputDollarsPerMillion: number;
  outputDollarsPerMillion: number;
}

/** "model=in/out,…" read into prices; the defaults, with the setting on top. */
export function modelPrices(pricesSetting?: string): Record<string, ModelPrice> {
  const prices: Record<string, ModelPrice> = {};
  for (const setting of [DEFAULT_MODEL_PRICES, pricesSetting ?? ""]) {
    for (const entry of setting.split(",")) {
      const match = entry.trim().match(/^([^=\s]+)\s*=\s*([0-9.]+)\s*\/\s*([0-9.]+)$/);
      if (!match) continue;
      const inputDollarsPerMillion = Number.parseFloat(match[2]);
      const outputDollarsPerMillion = Number.parseFloat(match[3]);
      if (!Number.isFinite(inputDollarsPerMillion) || !Number.isFinite(outputDollarsPerMillion)) continue;
      prices[match[1].toLowerCase()] = { inputDollarsPerMillion, outputDollarsPerMillion };
    }
  }
  return prices;
}

/** One answer's usage, sent to the app as `dottieUsage` and logged. */
export interface AnswerUsage {
  provider: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  seconds: number;
  /** Estimated cost; null when the model has no price set. */
  estimatedDollars: number | null;
}

export function answerUsage(
  providerName: string,
  model: string,
  usageMetadata: AnswerUsageMetadata | undefined,
  milliseconds: number,
  pricesSetting?: string
): AnswerUsage {
  const inputTokens = usageMetadata?.promptTokenCount ?? 0;
  const outputTokens = usageMetadata?.candidatesTokenCount ?? 0;
  const cacheReadTokens = Math.min(usageMetadata?.cachedContentTokenCount ?? 0, inputTokens);
  const cacheWriteTokens = Math.min(usageMetadata?.cacheWriteTokenCount ?? 0, inputTokens - cacheReadTokens);
  // Input at the full price, except what came from or went into the cache.
  const pricedInputTokens = inputTokens - cacheReadTokens - cacheWriteTokens
    + cacheReadTokens * CACHE_READ_PRICE_SHARE + cacheWriteTokens * CACHE_WRITE_PRICE_SHARE;
  const price = modelPrices(pricesSetting)[model.toLowerCase()];
  const estimatedDollars = price
    ? Math.round(((pricedInputTokens * price.inputDollarsPerMillion + outputTokens * price.outputDollarsPerMillion) / 1_000_000) * 1e8) / 1e8
    : null;
  return { provider: providerName, model, inputTokens, outputTokens, seconds: Math.round(milliseconds / 10) / 100, estimatedDollars };
}

/** Settings for one ask that aren't part of the body. */
export interface AnswerOptions {
  /** MODEL_PRICES, for the cost in each answer's usage. */
  pricesSetting?: string;
}

/**
 * Asks the provider's models in turn. Returns a Gemini-shaped response (one
 * SSE event when `streaming`), or undefined when every model failed. Each
 * answer carries `dottieUsage` (provider, model, tokens, seconds, cost) and
 * is logged as one "[usage]" line, so every ask's model and cost can be
 * followed in the app's log and the Worker's.
 */
export async function answerWithProvider(
  provider: ChatProvider,
  geminiBody: Record<string, unknown>,
  streaming: boolean,
  options: AnswerOptions = {}
): Promise<Response | undefined> {
  const models = imageCount(geminiBody) > 0 ? provider.visionModels : provider.textModels;
  // Groq's models write boxes in pixels, left first; Gemini's box_2d is
  // 0-1000, top first. Groq is asked for pixels and its answer turned back.
  const boxConversion = provider.usesPixelBoxes
    ? pixelBoxConversion(geminiBody)
    : provider.usesThousandGridLeftFirstBoxes
      ? pixelBoxConversion(geminiBody, THOUSAND_GRID_LEFT_FIRST)
      : undefined;
  const chatRequest = toChatRequest(boxConversion ? boxConversion.bodyForProvider : geminiBody);
  if (provider.name === "groq" && typeof chatRequest.max_tokens !== "number") {
    chatRequest.max_tokens = DEFAULT_ANSWER_TOKENS;
  }
  const speaksAnthropic = provider.format === "anthropic";
  const requestForProvider = speaksAnthropic ? toAnthropicRequest(chatRequest) : chatRequest;
  const headers: Record<string, string> = speaksAnthropic
    ? { "x-api-key": provider.apiKey, "anthropic-version": ANTHROPIC_VERSION, "content-type": "application/json", accept: "application/json" }
    : { authorization: `Bearer ${provider.apiKey}`, "content-type": "application/json", accept: "application/json" };
  for (const model of models) {
    const builtInTools = speaksAnthropic ? [] : provider.builtInToolsForModel?.(model) ?? [];
    for (const extras of [withBuiltInTools(provider.extrasForModel(model), requestForProvider, builtInTools), {}]) {
      const startedAt = Date.now();
      let response: Response;
      try {
        response = await fetch(provider.apiURL, {
          method: "POST",
          headers,
          body: JSON.stringify({ ...requestForProvider, ...extras, model, stream: false }),
          signal: AbortSignal.timeout(provider.attemptTimeoutMilliseconds),
        });
      } catch (error) {
        // Too slow or unreachable: the next model, or the caller's backup.
        console.warn(`[${provider.name}] ${model} didn't answer: ${error}`);
        break;
      }
      if (response.ok) {
        const providerResponse = await response.json<Record<string, unknown>>().catch(() => undefined);
        if (!providerResponse) break;
        const chatResponse = speaksAnthropic ? fromAnthropicResponse(providerResponse) : providerResponse;
        let geminiResponse = toGeminiResponse(chatResponse, `${provider.name}/${model}`);
        if (!geminiResponse) break;
        if (boxConversion) geminiResponse = boxConversion.responseForGemini(geminiResponse);
        const usage = answerUsage(provider.name, model, geminiResponse.usageMetadata as AnswerUsageMetadata | undefined, Date.now() - startedAt, options.pricesSetting);
        console.log(`[usage] ${JSON.stringify(usage)}`);
        geminiResponse = { ...geminiResponse, dottieUsage: usage };
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
      // Groq's gpt-oss sometimes writes a plain answer but calls it a
      // broken tool call (tool_use_failed) when the request had no tools.
      // The words it wrote are the answer.
      const salvagedText = response.status === 400 ? salvagedToolUseFailure(errorText, chatRequest) : undefined;
      if (salvagedText !== undefined) {
        const salvagedResponse = toGeminiResponse(
          { choices: [{ message: { role: "assistant", content: salvagedText }, finish_reason: "stop" }] },
          `${provider.name}/${model}`
        );
        if (salvagedResponse) {
          const payload = JSON.stringify(salvagedResponse);
          return streaming
            ? new Response(`data: ${payload}\r\n\r\n`, {
                status: 200,
                headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
              })
            : new Response(payload, { status: 200, headers: { "content-type": "application/json" } });
        }
      }
      // Only a rejected request is worth retrying without the extras.
      if (response.status !== 400 && response.status !== 422) break;
      if (Object.keys(extras).length === 0) break;
    }
  }
  return undefined;
}

/**
 * The words a model wrote when its provider refused the answer as a broken
 * tool call (`tool_use_failed` with `failed_generation`), or undefined.
 * Only for requests that offered no tools: then nothing was meant as a call.
 */
export function salvagedToolUseFailure(errorText: string, chatRequest: Record<string, unknown>): string | undefined {
  const offeredTools = Array.isArray(chatRequest.tools) && chatRequest.tools.length > 0;
  if (offeredTools) return undefined;
  let parsed: unknown;
  try {
    parsed = JSON.parse(errorText);
  } catch {
    return undefined;
  }
  const error = (parsed as { error?: { code?: unknown; failed_generation?: unknown } } | null)?.error;
  if (error?.code !== "tool_use_failed" || typeof error.failed_generation !== "string") return undefined;
  const text = unwrappedToolCallText(error.failed_generation.trim());
  return text.length > 0 ? text : undefined;
}

/**
 * gpt-oss sometimes wraps its words in a made-up call, like
 * {"name":"assistant","arguments":"REQUEST"} or the unquoted
 * {"name": "assistant<|channel|>final", "arguments": REQUEST.}. Those words
 * are the answer; celly saw the raw JSON read out as Dottie's reply.
 */
export function unwrappedToolCallText(text: string): string {
  if (!text.startsWith("{") || !text.includes('"arguments"')) return text;
  const match = /"arguments"\s*:\s*("?)([\s\S]*?)\1\s*}\s*$/.exec(text);
  if (!match) return text;
  let argumentsText = match[2].trim();
  // Arguments that are themselves an object: keep their first string value.
  if (argumentsText.startsWith("{")) {
    try {
      const values = Object.values(JSON.parse(argumentsText) as Record<string, unknown>);
      const firstString = values.find((value) => typeof value === "string");
      if (typeof firstString === "string") argumentsText = firstString;
    } catch {
      return text;
    }
  }
  return argumentsText.replace(/\\"/g, '"').trim();
}

// MARK: - Gemini → chat

export function toChatRequest(geminiBody: Record<string, unknown>): Record<string, unknown> {
  const messages: ChatMessage[] = [];

  let systemText = partsText(((geminiBody.systemInstruction ?? {}) as GeminiContent).parts);
  // The chat format only promises JSON, not Gemini's response schema, so
  // the schema's shape goes into the instructions.
  const responseSchema = ((geminiBody.generationConfig ?? {}) as Record<string, unknown>).responseSchema;
  if (responseSchema) {
    systemText += `${systemText ? "\n\n" : ""}Reply with only a JSON object matching this JSON schema:\n${JSON.stringify(lowercaseSchema(responseSchema))}`;
  }
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
export function lowercaseSchema(schema: unknown): unknown {
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

/**
 * The first try's extras with the provider's built-in tools added after the
 * request's own (a talker's hand_to_claude stays), and room for the search
 * in the answer tokens.
 */
export function withBuiltInTools(
  extras: Record<string, unknown>,
  request: Record<string, unknown>,
  builtInTools: Array<Record<string, unknown>>
): Record<string, unknown> {
  if (!builtInTools.length) return extras;
  const requestTools = Array.isArray(request.tools) ? (request.tools as Array<Record<string, unknown>>) : [];
  const answerTokens = typeof request.max_tokens === "number" ? request.max_tokens : 0;
  return {
    ...extras,
    tools: [...requestTools, ...builtInTools],
    max_tokens: Math.max(answerTokens, MINIMUM_ANSWER_TOKENS_WITH_BUILT_IN_TOOLS),
  };
}

/** GPT-OSS cites its search results as 【1†source】, which isn't for speaking. */
const SEARCH_CITATION_PATTERN = /【[^】]*】/g;

export function toGeminiResponse(chatResponse: Record<string, unknown>, answeringModel: string): Record<string, unknown> | undefined {
  const choice = ((chatResponse.choices ?? []) as Array<Record<string, unknown>>)[0];
  const message = (choice?.message ?? {}) as Record<string, unknown>;
  const parts: GeminiPart[] = [];

  // GLM wraps boxes in <|begin_of_box|>…<|end_of_box|>; the app wants the JSON.
  const text = typeof message.content === "string"
    ? message.content.replace(/<\|(begin|end)_of_box\|>/g, "").replace(SEARCH_CITATION_PATTERN, "").trim()
    : "";
  if (text) parts.push({ text });

  for (const toolCall of (message.tool_calls ?? []) as Array<Record<string, unknown>>) {
    const call = (toolCall.function ?? {}) as Record<string, unknown>;
    if (typeof call.name !== "string") continue;
    let args: unknown = {};
    try {
      args = typeof call.arguments === "string" ? JSON.parse(call.arguments) : call.arguments;
    } catch {
      args = {};
    }
    // Gemini only takes an object here; "" or null from a model would be turned down.
    if (!args || typeof args !== "object" || Array.isArray(args)) args = {};
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
      ...(usage.cache_read_tokens ? { cachedContentTokenCount: usage.cache_read_tokens } : {}),
      ...(usage.cache_write_tokens ? { cacheWriteTokenCount: usage.cache_write_tokens } : {}),
    },
    modelVersion: answeringModel,
  };
}

// MARK: - Pixel boxes for Groq

/**
 * Pointing asks for boxes as box_2d = [ymin, xmin, ymax, xmax] from 0 to
 * 1000 (Gemini's own format, also target_box_2d, player_box_2d and the
 * guide's target_box). Groq's vision model measures in pixels with left
 * first, and mixes the two up when asked for Gemini's order. So for Groq
 * every such key becomes a "_px" key in pixels of the newest picture,
 * [left, top, right, bottom], in the instructions, the schemas and earlier
 * calls in the history, and the answer's "_px" boxes are turned back into
 * the keys and 0-1000 boxes the app asked for.
 */
/** How a provider wants boxes when not in Gemini's box_2d: its key suffix and, for a fixed grid, the grid's size. */
export interface BoxStyle {
  keySuffix: string;
  /** A fixed grid (GLM's 0-1000); without it, pixels of the newest picture. */
  gridSize?: number;
}

const PIXELS_LEFT_FIRST: BoxStyle = { keySuffix: "box_px" };
export const THOUSAND_GRID_LEFT_FIRST: BoxStyle = { keySuffix: "box_xy", gridSize: 1000 };

export function pixelBoxConversion(geminiBody: Record<string, unknown>, boxStyle: BoxStyle = PIXELS_LEFT_FIRST):
  | { bodyForProvider: Record<string, unknown>; responseForGemini: (response: Record<string, unknown>) => Record<string, unknown> }
  | undefined {
  const bodyText = JSON.stringify(geminiBody);
  const mentionsBoxes = bodyText.includes("box_2d") || bodyText.includes("\"target_box\"");
  if (!mentionsBoxes) return undefined;
  const pictureSize = boxStyle.gridSize
    ? { width: boxStyle.gridSize, height: boxStyle.gridSize }
    : newestPictureSize(geminiBody);
  if (!pictureSize) return undefined;
  const suffix = boxStyle.keySuffix;

  const originalKeyByPixelKey = new Map<string, string>();
  const pixelKey = (key: string): string | undefined => {
    let renamed: string | undefined;
    if (key.endsWith("box_2d")) renamed = `${key.slice(0, -"box_2d".length)}${suffix}`;
    else if (key === "target_box") renamed = `target_${suffix}`;
    if (renamed) originalKeyByPixelKey.set(renamed, key);
    return renamed;
  };

  const renameInText = (text: string): string =>
    text
      .replace(/\b([a-z_]*)box_2d\b/g, (_match, prefix: string) => pixelKey(`${prefix}box_2d`)!)
      .replace(/\btarget_box\b(?!_)/g, () => pixelKey("target_box")!)
      .replace(/\[\s*ymin\s*,\s*xmin\s*,\s*ymax\s*,\s*xmax\s*\]/g, "[left, top, right, bottom]");

  // Gemini boxes in earlier calls of a job, so the history agrees.
  const toPixels = (value: unknown): unknown => {
    const box = boxNumbers(value);
    if (!box) return value;
    const [ymin, xmin, ymax, xmax] = box;
    return [
      Math.round((xmin / 1000) * pictureSize.width),
      Math.round((ymin / 1000) * pictureSize.height),
      Math.round((xmax / 1000) * pictureSize.width),
      Math.round((ymax / 1000) * pictureSize.height),
    ];
  };
  const toGeminiBox = (value: unknown): unknown => {
    const box = boxNumbers(value);
    if (!box) return value;
    const [left, top, right, bottom] = box;
    const scaled = (pixels: number, size: number) => Math.min(1000, Math.max(0, Math.round((pixels / size) * 1000)));
    return [
      scaled(Math.min(top, bottom), pictureSize.height),
      scaled(Math.min(left, right), pictureSize.width),
      scaled(Math.max(top, bottom), pictureSize.height),
      scaled(Math.max(left, right), pictureSize.width),
    ];
  };

  const renameKeys = (value: unknown, convertBox: ((box: unknown) => unknown) | undefined, keyFor: (key: string) => string | undefined): unknown => {
    if (Array.isArray(value)) return value.map((item) => renameKeys(item, convertBox, keyFor));
    if (!value || typeof value !== "object") return typeof value === "string" && !convertBox ? renameInText(value) : value;
    const renamedObject: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
      const newKey = keyFor(key);
      if (newKey) {
        renamedObject[newKey] = convertBox ? convertBox(item) : renameKeys(item, convertBox, keyFor);
      } else if (key === "required" && Array.isArray(item)) {
        renamedObject[key] = item.map((name) => (typeof name === "string" ? keyFor(name) ?? name : name));
      } else {
        renamedObject[key] = renameKeys(item, convertBox, keyFor);
      }
    }
    return renamedObject;
  };

  const bodyForProvider = structuredClone(geminiBody);
  for (const content of (bodyForProvider.contents ?? []) as GeminiContent[]) {
    for (const part of content.parts ?? []) {
      if (typeof part.text === "string") part.text = renameInText(part.text);
      if (part.functionCall?.args) part.functionCall.args = renameKeys(part.functionCall.args, toPixels, pixelKey);
    }
  }
  // Schemas and descriptions: keys renamed, and text inside them too.
  if (bodyForProvider.tools) bodyForProvider.tools = renameKeys(bodyForProvider.tools, undefined, pixelKey);
  const generationConfig = (bodyForProvider.generationConfig ?? {}) as Record<string, unknown>;
  if (generationConfig.responseSchema) {
    generationConfig.responseSchema = renameKeys(generationConfig.responseSchema, undefined, pixelKey);
  }
  const systemInstruction = (bodyForProvider.systemInstruction ?? { parts: [] }) as GeminiContent;
  const systemParts = (systemInstruction.parts ?? []).map((part) =>
    typeof part.text === "string" ? { ...part, text: renameInText(part.text) } : part
  );
  const boxKeyNames = [...new Set(originalKeyByPixelKey.keys())].join(", ") || suffix;
  systemParts.push({
    text: boxStyle.gridSize
      ? `Boxes: give every box (${boxKeyNames}) on a 0-${boxStyle.gridSize} grid over the newest image as [left, top, right, bottom] ` +
        `(x first: left and right go across, top and bottom go down), tight around the thing.`
      : `Boxes: ignore any 0-1000 scale described above. The newest image is ${pictureSize.width}×${pictureSize.height} pixels. ` +
        `Give every box (${boxKeyNames}) in pixels of that image as [left, top, right, bottom], ` +
        `measured on the image itself, tight around the thing.`,
  });
  bodyForProvider.systemInstruction = { ...systemInstruction, parts: systemParts };

  const geminiKey = (key: string): string | undefined =>
    originalKeyByPixelKey.get(key) ?? (key.endsWith(suffix) ? `${key.slice(0, -suffix.length)}box_2d` : undefined);

  const responseForGemini = (response: Record<string, unknown>): Record<string, unknown> => {
    const converted = structuredClone(response);
    for (const candidate of (converted.candidates ?? []) as Array<{ content?: GeminiContent }>) {
      for (const part of candidate.content?.parts ?? []) {
        if (part.functionCall?.args) part.functionCall.args = renameKeys(part.functionCall.args, toGeminiBox, geminiKey);
        if (typeof part.text === "string") part.text = textWithGeminiBoxes(part.text, toGeminiBox, geminiKey, suffix);
      }
    }
    return converted;
  };

  return { bodyForProvider, responseForGemini };
}

/** "box_px": [l, t, r, b] in an answer's text (JSON or close to it) → Gemini's key and box. */
export function textWithGeminiBoxes(
  text: string,
  toGeminiBox: (box: unknown) => unknown,
  geminiKey: (key: string) => string | undefined,
  keySuffix = "box_px"
): string {
  const number = String.raw`-?\d+(?:\.\d+)?`;
  const boxPattern = new RegExp(
    String.raw`"([a-z_]*${keySuffix})"\s*:\s*\[?\s*(${number})\s*,\s*(${number})\s*,\s*(${number})\s*,\s*(${number})\s*\]?`,
    "g"
  );
  return text
    .replace(boxPattern, (_match, key: string, left: string, top: string, right: string, bottom: string) => {
      const box = toGeminiBox([Number(left), Number(top), Number(right), Number(bottom)]);
      return `"${geminiKey(key) ?? key}": ${JSON.stringify(box)}`;
    })
    .replace(new RegExp(`"([a-z_]*${keySuffix})"`, "g"), (_match, key: string) => `"${geminiKey(key) ?? key}"`);
}

function boxNumbers(value: unknown): [number, number, number, number] | undefined {
  if (!Array.isArray(value) || value.length !== 4) return undefined;
  const numbers = value.map((item) => Number(item));
  return numbers.every((item) => Number.isFinite(item)) ? (numbers as [number, number, number, number]) : undefined;
}

/** Width and height of the body's newest picture, read from its JPEG or PNG header. */
function newestPictureSize(geminiBody: Record<string, unknown>): { width: number; height: number } | undefined {
  let newestPictureBase64: string | undefined;
  for (const content of (geminiBody.contents ?? []) as GeminiContent[]) {
    for (const part of content.parts ?? []) {
      if ((part.inlineData?.mimeType ?? "").startsWith("image/") && part.inlineData?.data) newestPictureBase64 = part.inlineData.data;
    }
  }
  if (!newestPictureBase64) return undefined;
  // The header is near the start; a little of the picture is enough.
  const headerBase64 = newestPictureBase64.slice(0, 87_384).replace(/=+$/, "");
  const usableLength = headerBase64.length - (headerBase64.length % 4);
  let bytes: Uint8Array;
  try {
    bytes = Uint8Array.from(atob(headerBase64.slice(0, usableLength)), (character) => character.charCodeAt(0));
  } catch {
    return undefined;
  }
  return pictureSize(bytes);
}

export function pictureSize(bytes: Uint8Array): { width: number; height: number } | undefined {
  // PNG: the IHDR chunk right after the signature.
  if (bytes.length >= 24 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const width = view.getUint32(16);
    const height = view.getUint32(20);
    return width > 0 && height > 0 ? { width, height } : undefined;
  }
  // JPEG: walk the markers to the start-of-frame one.
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return undefined;
  let offset = 2;
  while (offset + 9 < bytes.length) {
    if (bytes[offset] !== 0xff) {
      offset += 1;
      continue;
    }
    const marker = bytes[offset + 1];
    if (marker === 0xff) {
      offset += 1;
      continue;
    }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd9)) {
      offset += 2;
      continue;
    }
    const segmentLength = (bytes[offset + 2] << 8) | bytes[offset + 3];
    const isStartOfFrame = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isStartOfFrame) {
      const height = (bytes[offset + 5] << 8) | bytes[offset + 6];
      const width = (bytes[offset + 7] << 8) | bytes[offset + 8];
      return width > 0 && height > 0 ? { width, height } : undefined;
    }
    offset += 2 + segmentLength;
  }
  return undefined;
}
