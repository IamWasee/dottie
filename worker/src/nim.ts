/**
 * NVIDIA NIM as a last resort when every Gemini model is busy or out of
 * free quota. NIM's hosted API (build.nvidia.com) speaks OpenAI's chat
 * format, so this turns a Gemini generateContent body into a chat request
 * and the answer back into a Gemini response; the app and Gemini CLI never
 * know the difference.
 *
 * Only used when the NVIDIA_API_KEY secret is set. NIM's free endpoints are
 * slower than Gemini and have their own limits (about 40 requests a minute
 * per key), so it's a backup, not a replacement. Voice (Live), speech and
 * dictation stay on Gemini: NIM has no audio models here.
 */

const NIM_API_URL = "https://integrate.api.nvidia.com/v1/chat/completions";

/** Vision + tool-calling models on NIM's free endpoints, best first. */
export const DEFAULT_NIM_MODELS = "z-ai/glm-5.3-flash,deepseek-ai/deepseek-v4.1-flash";

type GeminiPart = {
  text?: string;
  thought?: boolean;
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

/** True when NIM can answer this body: text and pictures, not audio out. */
export function canUseNim(geminiBody: Record<string, unknown>): boolean {
  const generationConfig = (geminiBody.generationConfig ?? {}) as Record<string, unknown>;
  const modalities = (generationConfig.responseModalities ?? []) as string[];
  return !modalities.some((modality) => String(modality).toUpperCase() === "AUDIO");
}

/**
 * Asks NIM models in turn. Returns a Gemini-shaped response (one SSE event
 * when `streaming`), or undefined when every NIM model failed too.
 */
export async function answerWithNim(
  geminiBody: Record<string, unknown>,
  apiKey: string,
  modelList: string | undefined,
  streaming: boolean
): Promise<Response | undefined> {
  const models = (modelList || DEFAULT_NIM_MODELS).split(",").map((name) => name.trim()).filter(Boolean);
  const chatRequest = toChatRequest(geminiBody);
  for (const model of models) {
    // Thinking off for speed; some models reject the switch, so retry bare.
    for (const extras of [{ chat_template_kwargs: { enable_thinking: false, thinking: false } }, {}]) {
      const response = await fetch(NIM_API_URL, {
        method: "POST",
        headers: {
          authorization: `Bearer ${apiKey}`,
          "content-type": "application/json",
          accept: "application/json",
        },
        body: JSON.stringify({ ...chatRequest, ...extras, model, stream: false }),
      });
      if (response.ok) {
        const chatResponse = (await response.json()) as Record<string, unknown>;
        const geminiResponse = toGeminiResponse(chatResponse, model);
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
      console.warn(`[nim] ${model} answered ${response.status}: ${errorText.slice(0, 300)}`);
      // Only a rejected request is worth retrying without the extras.
      if (response.status !== 400 && response.status !== 422) break;
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
    if (userContent.length) messages.push({ role: "user", content: userContent });
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

function toGeminiResponse(chatResponse: Record<string, unknown>, model: string): Record<string, unknown> | undefined {
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
    parts.push({ functionCall: { name: call.name, args, ...(typeof toolCall.id === "string" ? { id: toolCall.id } : {}) } });
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
    modelVersion: `nim/${model}`,
  };
}
