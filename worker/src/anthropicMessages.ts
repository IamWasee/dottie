/**
 * Claude through Anthropic's own Messages API (/v1/messages). The app and
 * Gemini CLI speak Gemini's format; chatCompletions.ts already turns that
 * into OpenAI's chat format, so this turns the chat request into a
 * Messages request and Claude's answer back into a chat answer, which
 * toGeminiResponse finishes. Claude is asked in its own format, not
 * through an OpenAI-compatible shim, so pictures, tools and tool results
 * keep their meaning.
 */

export const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages";
export const ANTHROPIC_VERSION = "2023-06-01";

/** Messages requires an answer size; this covers a screen step or a helper's turn. */
export const DEFAULT_ANTHROPIC_ANSWER_TOKENS = 4096;

type ChatContentItem = Record<string, unknown>;
type ChatMessage = {
  role?: string;
  content?: string | ChatContentItem[] | null;
  tool_calls?: Array<{ id?: string; function?: { name?: string; arguments?: string } }>;
  tool_call_id?: string;
};
type AnthropicBlock = Record<string, unknown>;
type AnthropicMessage = { role: "user" | "assistant"; content: AnthropicBlock[] };

/** A data: URL picture as Claude's base64 image block, or undefined for anything else. */
export function imageBlockFromDataURL(url: unknown): AnthropicBlock | undefined {
  if (typeof url !== "string") return undefined;
  const match = url.match(/^data:([^;,]+);base64,(.+)$/s);
  if (!match) return undefined;
  return { type: "image", source: { type: "base64", media_type: match[1], data: match[2] } };
}

function blocksFromChatContent(content: ChatMessage["content"]): AnthropicBlock[] {
  if (typeof content === "string") return content ? [{ type: "text", text: content }] : [];
  const blocks: AnthropicBlock[] = [];
  for (const item of content ?? []) {
    if (item.type === "text" && typeof item.text === "string" && item.text) {
      blocks.push({ type: "text", text: item.text });
    } else if (item.type === "image_url") {
      const image = imageBlockFromDataURL((item.image_url as Record<string, unknown> | undefined)?.url);
      if (image) blocks.push(image);
    }
  }
  return blocks;
}

function parsedArguments(argumentsText: string | undefined): Record<string, unknown> {
  try {
    const parsed = JSON.parse(argumentsText || "{}");
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

/**
 * The chat request (from toChatRequest) as a Messages request. Claude wants
 * the system text on its own, turns that alternate user/assistant starting
 * with the user, and tool results as blocks in a user turn.
 */
export function toAnthropicRequest(chatRequest: Record<string, unknown>): Record<string, unknown> {
  const systemTexts: string[] = [];
  const messages: AnthropicMessage[] = [];

  const addBlocks = (role: "user" | "assistant", blocks: AnthropicBlock[]) => {
    if (!blocks.length) return;
    const previous = messages[messages.length - 1];
    if (previous && previous.role === role) {
      // Tool results must come before anything else in a user turn.
      previous.content = role === "user"
        ? [...previous.content.filter((block) => block.type === "tool_result"), ...blocks.filter((block) => block.type === "tool_result"),
           ...previous.content.filter((block) => block.type !== "tool_result"), ...blocks.filter((block) => block.type !== "tool_result")]
        : [...previous.content, ...blocks];
    } else {
      messages.push({ role, content: blocks });
    }
  };

  for (const message of (chatRequest.messages ?? []) as ChatMessage[]) {
    if (message.role === "system") {
      const text = typeof message.content === "string" ? message.content : blocksFromChatContent(message.content).map((block) => block.text).join("\n");
      if (text) systemTexts.push(text);
    } else if (message.role === "assistant") {
      const blocks = blocksFromChatContent(message.content);
      for (const toolCall of message.tool_calls ?? []) {
        if (!toolCall.function?.name) continue;
        blocks.push({ type: "tool_use", id: toolCall.id || `call_${messages.length}_${blocks.length}`, name: toolCall.function.name, input: parsedArguments(toolCall.function.arguments) });
      }
      addBlocks("assistant", blocks);
    } else if (message.role === "tool") {
      const resultText = typeof message.content === "string" ? message.content : JSON.stringify(message.content ?? "");
      addBlocks("user", [{ type: "tool_result", tool_use_id: message.tool_call_id ?? "", content: resultText || "{}" }]);
    } else {
      addBlocks("user", blocksFromChatContent(message.content));
    }
  }

  // Claude needs the conversation to start with the user.
  if (!messages.length || messages[0].role !== "user") {
    messages.unshift({ role: "user", content: [{ type: "text", text: "Go on." }] });
  }

  if (chatRequest.response_format) {
    systemTexts.push("Reply with only the JSON object, with no words or code fences around it.");
  }

  const anthropicRequest: Record<string, unknown> = {
    max_tokens: typeof chatRequest.max_tokens === "number" ? chatRequest.max_tokens : DEFAULT_ANTHROPIC_ANSWER_TOKENS,
    messages,
  };
  if (systemTexts.length) anthropicRequest.system = systemTexts.join("\n\n");
  if (typeof chatRequest.temperature === "number") anthropicRequest.temperature = Math.min(1, Math.max(0, chatRequest.temperature));

  const tools = (chatRequest.tools ?? []) as Array<{ function?: { name?: string; description?: string; parameters?: unknown } }>;
  if (tools.length) {
    anthropicRequest.tools = tools
      .filter((tool) => tool.function?.name)
      .map((tool) => ({
        name: tool.function!.name,
        description: tool.function!.description ?? "",
        input_schema: tool.function!.parameters && typeof tool.function!.parameters === "object"
          ? tool.function!.parameters
          : { type: "object", properties: {} },
      }));
    // Tools are the same every turn: Claude keeps them cached, so later
    // turns pay a tenth for them. Too short a list is simply not cached.
    const toolList = anthropicRequest.tools as Array<Record<string, unknown>>;
    if (toolList.length) toolList[toolList.length - 1].cache_control = { type: "ephemeral" };
    const choice = chatRequest.tool_choice;
    anthropicRequest.tool_choice = choice === "required" ? { type: "any" } : choice === "none" ? { type: "none" } : { type: "auto" };
  }
  return anthropicRequest;
}

/** Claude's answer as an OpenAI-style chat answer, for toGeminiResponse. */
export function fromAnthropicResponse(anthropicResponse: Record<string, unknown>): Record<string, unknown> {
  const texts: string[] = [];
  const toolCalls: Array<Record<string, unknown>> = [];
  for (const block of (anthropicResponse.content ?? []) as AnthropicBlock[]) {
    if (block.type === "text" && typeof block.text === "string") {
      texts.push(block.text);
    } else if (block.type === "tool_use" && typeof block.name === "string") {
      toolCalls.push({ id: block.id, type: "function", function: { name: block.name, arguments: JSON.stringify(block.input ?? {}) } });
    }
  }
  const usage = (anthropicResponse.usage ?? {}) as Record<string, number>;
  const promptTokens = (usage.input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0);
  const completionTokens = usage.output_tokens ?? 0;
  return {
    choices: [{
      message: { content: texts.join("\n"), ...(toolCalls.length ? { tool_calls: toolCalls } : {}) },
      finish_reason: anthropicResponse.stop_reason === "max_tokens" ? "length" : "stop",
    }],
    usage: { prompt_tokens: promptTokens, completion_tokens: completionTokens, total_tokens: promptTokens + completionTokens },
  };
}
