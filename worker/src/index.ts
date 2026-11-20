/**
 * Dottie's Worker
 *
 * Holds the model keys so the app never ships with them. No Gemini behind
 * it any more: requests still use Gemini's body format (the app and Gemini
 * CLI speak it) and are answered by Claude, GLM, Groq or NIM.
 *
 * Routes:
 *   POST /chat       → streamed answer in Gemini's SSE format. "provider":
 *                      "talk" is Groq's small talk model, "request" is
 *                      Claude; anything else goes to the paid providers
 *                      (paidProviders), then Groq, then NIM.
 *   GET  /search?q=  → free web search (Bing, DuckDuckGo, Wikipedia).
 *   POST /jev        → Jev (TypeSafe's System One): boxes and done checks.
 *   GET  /config     → non-secret model names, for debugging.
 *   ANY  /gemini/*   → the Dots' route: Gemini CLI is pointed here with
 *                      GOOGLE_GEMINI_BASE_URL and sends the shared secret as
 *                      its "API key"; its model calls get the same models.
 *   /phone/*, /telegram/webhook → Dottie's phone bot (phoneRelay.ts).
 *   GET  /health     → up, and has a model key.
 *
 * Optional: set the APP_SHARED_SECRET secret and the same value as
 * ClickyAppSharedSecret in the app's Info.plist. Requests without the
 * matching `x-clicky-secret` header are rejected, so a stranger who finds
 * your worker URL can't spend your keys.
 */

export interface Env {
  APP_SHARED_SECRET?: string;
  /** Free Groq key; when set, quick asks go to Groq first (see handleChat). */
  GROQ_API_KEY?: string;
  /** Comma-separated Groq models for text-only requests, best first. */
  GROQ_TEXT_MODELS?: string;
  /** Comma-separated Groq models for requests with pictures, best first. */
  GROQ_VISION_MODELS?: string;
  /** Free NVIDIA NIM key; when set, NIM answers when every Gemini model is busy. */
  NVIDIA_API_KEY?: string;
  /** Comma-separated NIM models to try, in order. */
  NIM_MODELS?: string;
  /** Biggest request (prompt + answer, in tokens) sent to Groq; 7000 fits its free plan. */
  GROQ_MAX_REQUEST_TOKENS?: string;
  /** Paid Claude key; when set, text asks and Dot turns go to Claude first (see paidProviders). */
  ANTHROPIC_API_KEY?: string;
  /** Comma-separated Claude models, best first. */
  ANTHROPIC_MODELS?: string;
  /** Paid Z.ai key; when set, asks with pictures (screen steps, pointing) go to GLM first. */
  ZAI_API_KEY?: string;
  /** Comma-separated GLM models, best first. */
  ZAI_MODELS?: string;
  /** Paid TypeSafe key for Jev (/jev): finding what to click and done checks. */
  JEV_API_KEY?: string;
  /** Jev model id; "jev-latest" by default. */
  JEV_MODEL?: string;
  /** Who answers first: "glm,claude" for asks with pictures, "claude,glm" for text by default. */
  PICTURE_PROVIDER_ORDER?: string;
  TEXT_PROVIDER_ORDER?: string;
  HELPER_PROVIDER_ORDER?: string;
  GROQ_TALK_MODELS?: string;
  REQUEST_PROVIDER_ORDER?: string;
  /** Dottie's own Telegram bot, for one-tap phone pairing (see phoneRelay.ts). */
  TELEGRAM_BOT_TOKEN?: string;
  PHONE_RELAY: DurableObjectNamespace;
  /** Cloudflare's rate limiter (wrangler.toml); absent in a setup without it, and then nothing is limited. */
  REQUEST_RATE_LIMITER?: RateLimit;
  /** Each install's counts for the day (usageLimits.ts); absent in a setup without it, and then nothing is counted. */
  INSTALL_USAGE?: DurableObjectNamespace;
  /** "voice=300,chat=3000,…": the day's limit per area for one install. */
  INSTALL_DAILY_LIMITS?: string;
  /** Comma-separated install ids that are never limited. */
  UNLIMITED_INSTALL_IDS?: string;
}

/**
 * Biggest body a route takes, by its Content-Length. A long screen job
 * with a screenshot every step is about 10 MB; files for the phone (up to
 * 50 MB, Telegram's own limit) go through /phone/ and get more room.
 */
const MAXIMUM_BODY_BYTES = 32 * 1024 * 1024;
const MAXIMUM_PHONE_FILE_BYTES = 52 * 1024 * 1024;

/**
 * What the Dots' Gemini-shaped route answers: calling a model, counting
 * tokens and listing models. Everything else Gemini CLI might ask for
 * (uploading files, cached content, embeddings) is turned away.
 */
const PASSTHROUGH_MODEL_CALL = /^\/v1(?:alpha|beta)?\/models\/[^/:]+:(?:generateContent|streamGenerateContent|countTokens)$/;
const PASSTHROUGH_MODEL_LISTING = /^\/v1(?:alpha|beta)?\/models(?:\/[^/:]+)?$/;

export function isAllowedPassthrough(method: string, upstreamPath: string): boolean {
  if (method === "POST") return PASSTHROUGH_MODEL_CALL.test(upstreamPath);
  if (method === "GET") return PASSTHROUGH_MODEL_LISTING.test(upstreamPath);
  return false;
}

/** The biggest body the route at this address takes. */
function maximumBodyBytes(url: URL): number {
  return url.pathname.startsWith("/phone/") ? MAXIMUM_PHONE_FILE_BYTES : MAXIMUM_BODY_BYTES;
}

/**
 * The request, once its body is known to fit the route, or undefined when
 * it is too big. A body that says its size is taken at its word (the
 * network layer cuts it off there). A body sent in pieces with no size is
 * counted as it arrives and dropped the moment it goes over, so leaving
 * the size out is no way around the limit.
 */
export async function requestWithinSizeLimit(request: Request, maximumBytes: number): Promise<Request | undefined> {
  const declaredSize = request.headers.get("content-length");
  if (declaredSize !== null && Number.isFinite(Number(declaredSize))) {
    return Number(declaredSize) > maximumBytes ? undefined : request;
  }
  if (!request.body) return request;

  const bodyReader = request.body.getReader();
  const receivedChunks: Uint8Array[] = [];
  let receivedBytes = 0;
  for (;;) {
    const { done, value } = await bodyReader.read();
    if (done) break;
    receivedBytes += value.byteLength;
    if (receivedBytes > maximumBytes) {
      await bodyReader.cancel();
      return undefined;
    }
    receivedChunks.push(value);
  }
  const wholeBody = new Uint8Array(receivedBytes);
  let writeOffset = 0;
  for (const chunk of receivedChunks) {
    wholeBody.set(chunk, writeOffset);
    writeOffset += chunk.byteLength;
  }
  return new Request(request.url, { method: request.method, headers: request.headers, body: wholeBody });
}

/**
 * True when this caller has used up its requests for the minute. Counted
 * per address, so one person hammering the Worker can't spend everyone's
 * quota. A limiter that fails never blocks anyone.
 */
async function isOverRateLimit(request: Request, env: Env): Promise<boolean> {
  if (!env.REQUEST_RATE_LIMITER) return false;
  const callerAddress = request.headers.get("cf-connecting-ip") ?? "unknown";
  try {
    const { success } = await env.REQUEST_RATE_LIMITER.limit({ key: callerAddress });
    return !success;
  } catch (error) {
    console.warn(`[rate limit] the limiter failed: ${error}`);
    return false;
  }
}

function tooManyRequestsResponse(): Response {
  return new Response(JSON.stringify({ error: "Too many requests. Wait a minute and try again." }), {
    status: 429,
    headers: { "content-type": "application/json", "retry-after": "60" },
  });
}

/** What a caller is told when something breaks here; the detail goes to the log only. */
const SERVER_ERROR_MESSAGE = "Something went wrong on Dottie's server.";

import { handleJev } from "./jev";
import { anthropicProvider, answerWithProvider, canAnswer, estimatedTokens, fittedForProvider, groqProvider, imageCount, nimProvider, zaiProvider, type ChatProvider } from "./chatCompletions";
import { isSameSecret, jsonResponse, readJSONObject } from "./http";
import { handlePhoneRelay } from "./phoneRelay";
import { handleSearch } from "./search";
import { splitPassthroughKey, usageRefusal } from "./usageLimits";
export { PhoneRelay } from "./phoneRelay";
export { InstallUsage } from "./usageLimits";

export default {
  async fetch(incomingRequest: Request, env: Env): Promise<Response> {
    const url = new URL(incomingRequest.url);

    const request = await requestWithinSizeLimit(incomingRequest, maximumBodyBytes(url));
    if (!request) {
      return jsonResponse({ error: "That request is too big." }, 413);
    }

    // Gemini CLI can only send an "API key", so the Dots' route
    // authenticates with that key instead of x-clicky-secret. Google's
    // clients send it as x-goog-api-key or, some of them, as ?key=.
    if (url.pathname.startsWith("/gemini/")) {
      // The app puts its install id after the secret ("secret:install-id").
      const sentKey = splitPassthroughKey(request.headers.get("x-goog-api-key") ?? url.searchParams.get("key") ?? "").secret;
      if (env.APP_SHARED_SECRET && !isSameSecret(sentKey, env.APP_SHARED_SECRET)) {
        return new Response("Unauthorized", { status: 401 });
      }
      const upstreamPath = url.pathname.slice("/gemini".length);
      if (!isAllowedPassthrough(request.method, upstreamPath)) {
        return jsonResponse({ error: "This part of the Gemini API isn't available through Dottie." }, 403);
      }
      if (await isOverRateLimit(request, env)) return tooManyRequestsResponse();
      const passthroughUsageRefusal = await usageRefusal(request, url, env);
      if (passthroughUsageRefusal) return passthroughUsageRefusal;
      try {
        return await handleGeminiPassthrough(request, url, env);
      } catch (error) {
        console.error(`[/gemini] Unhandled error:`, error);
        return jsonResponse({ error: SERVER_ERROR_MESSAGE }, 500);
      }
    }

    // Telegram's webhook for Dottie's phone bot carries its own secret.
    if (url.pathname === "/telegram/webhook") {
      return (await handlePhoneRelay(request, url, env)) ?? new Response("Not found", { status: 404 });
    }

    // Open to anyone: says the Worker is up and has a model key, nothing more.
    // The release workflow and Dottie's Settings use it to check an address.
    // It doesn't say which other keys are set or whether a secret is
    // needed: that would tell a stranger what is worth trying.
    if (request.method === "GET" && url.pathname === "/health") {
      return jsonResponse({
        ok: true,
        app: "dottie",
        hasModelKey: Boolean(env.ANTHROPIC_API_KEY || env.ZAI_API_KEY || env.GROQ_API_KEY || env.NVIDIA_API_KEY),
      });
    }

    const presentedSecret = request.headers.get("x-clicky-secret") ?? splitPassthroughKey(request.headers.get("x-goog-api-key") ?? "").secret;
    if (env.APP_SHARED_SECRET && !isSameSecret(presentedSecret, env.APP_SHARED_SECRET)) {
      return new Response("Unauthorized", { status: 401 });
    }

    // The Mac's long poll for phone messages (one call every 25 seconds) isn't counted.
    const isPhoneLongPoll = url.pathname === "/phone/telegram/getUpdates";
    if (!isPhoneLongPoll && (await isOverRateLimit(request, env))) return tooManyRequestsResponse();
    const usageRefusalResponse = await usageRefusal(request, url, env);
    if (usageRefusalResponse) return usageRefusalResponse;

    try {
      const phoneRelayResponse = await handlePhoneRelay(request, url, env);
      if (phoneRelayResponse) return phoneRelayResponse;

      if (request.method === "GET" && url.pathname === "/search") {
        return await handleSearch(url);
      }

      if (request.method === "GET" && url.pathname === "/config") {
        return jsonResponse({
          groq: env.GROQ_API_KEY
            ? { textModels: env.GROQ_TEXT_MODELS || "default", visionModels: env.GROQ_VISION_MODELS || "default" }
            : "off",
          nimBackup: env.NVIDIA_API_KEY ? env.NIM_MODELS || "default" : "off",
          claude: env.ANTHROPIC_API_KEY ? env.ANTHROPIC_MODELS || "default" : "off",
          glm: env.ZAI_API_KEY ? env.ZAI_MODELS || "default" : "off",
          jev: env.JEV_API_KEY ? env.JEV_MODEL || "default" : "off",
        });
      }

      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405 });
      }

      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/jev") {
        return await handleJev(request, env.JEV_API_KEY, env.JEV_MODEL);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return jsonResponse({ error: SERVER_ERROR_MESSAGE }, 500);
    }

    return new Response("Not found", { status: 404 });
  },
};

/**
 * Answers a chat request in Gemini's request and streaming format (the app
 * and Gemini CLI speak it) with no Gemini behind it. The optional
 * "provider" field picks the route: "talk" is Groq's small talk model
 * alone, "request" is Claude alone. Anything else goes to the paid
 * providers first (paidProviders), then Groq ("provider": "groq" or not),
 * then NIM; when none of them answers the caller gets a 503.
 */
async function handleChat(request: Request, env: Env): Promise<Response> {
  const requestBody = await readJSONObject(request);
  if (!requestBody) {
    return jsonResponse({ error: "the body must be a JSON object" }, 400);
  }
  const wantedRole = requestBody.provider;
  delete requestBody.model;
  delete requestBody.provider;

  // Talking: Groq alone, on its small talk model, text only.
  if (wantedRole === "talk") return await answerTalk(env, requestBody);
  // Requests the talker handed over: Claude (Haiku) only, nothing else.
  if (wantedRole === "request") {
    const requestOrder = env.REQUEST_PROVIDER_ORDER || "claude";
    if (paidProviders(env, requestBody, false, requestOrder).length === 0) {
      console.warn(`[/chat] no key for the request route (${requestOrder}): set ANTHROPIC_API_KEY`);
      return jsonResponse({ error: "Claude couldn't answer this request" }, 503);
    }
    const requestResponse = await answerWithPaidProviders(env, requestBody, true, "/chat", requestOrder);
    return requestResponse ?? jsonResponse({ error: "Claude couldn't answer this request" }, 503);
  }

  const answer = await answerWithAnyProvider(env, requestBody, true, "/chat");
  return answer ?? jsonResponse({ error: NO_MODEL_ANSWERED_MESSAGE }, 503);
}

/** What a caller hears when every model is busy, down or has no key. */
const NO_MODEL_ANSWERED_MESSAGE = "No model could answer right now. Try again in a moment.";

/**
 * The paid providers, then Groq, then NIM; undefined when none answered.
 * Screen jobs send a screenshot every step, so each one gets only as much
 * of the request as fits it.
 */
async function answerWithAnyProvider(
  env: Env,
  geminiBody: Record<string, unknown>,
  streaming: boolean,
  routeName: string
): Promise<Response | undefined> {
  const paidResponse = await answerWithPaidProviders(env, geminiBody, streaming, routeName);
  if (paidResponse) return paidResponse;
  const backups: ChatProvider[] = [];
  const groq = groqFromEnv(env);
  if (groq) backups.push(groq);
  if (env.NVIDIA_API_KEY) backups.push(nimProvider(env.NVIDIA_API_KEY, env.NIM_MODELS));
  for (const backup of backups) {
    const fittedBody = fittedForProvider(backup, geminiBody, routeName === "/chat");
    if (!canAnswer(backup, fittedBody)) {
      console.warn(`[${routeName}] too big for ${backup.name}`);
      continue;
    }
    const backupResponse = await answerWithProvider(backup, fittedBody, streaming);
    if (backupResponse) return backupResponse;
    console.warn(`[${routeName}] ${backup.name} couldn't answer`);
  }
  console.error(`[${routeName}] no model answered`);
  return undefined;
}

/**
 * The paid providers whose keys are set, in the order they answer: GLM
 * first for asks with pictures (screen steps, pointing), only GLM for
 * helpers' text turns (celly's call), Claude first for other text. PICTURE_PROVIDER_ORDER,
 * HELPER_PROVIDER_ORDER and TEXT_PROVIDER_ORDER change the order without a
 * code change.
 */
export function paidProviders(env: Env, geminiBody: Record<string, unknown>, isHelperTurn = false, forcedOrder?: string): ChatProvider[] {
  const available: Record<string, ChatProvider | undefined> = {
    claude: env.ANTHROPIC_API_KEY ? anthropicProvider(env.ANTHROPIC_API_KEY, env.ANTHROPIC_MODELS) : undefined,
    glm: env.ZAI_API_KEY ? zaiProvider(env.ZAI_API_KEY, env.ZAI_MODELS) : undefined,
  };
  let order: string;
  if (forcedOrder) {
    order = forcedOrder;
  } else if (imageCount(geminiBody) > 0) {
    order = env.PICTURE_PROVIDER_ORDER || "glm,claude";
  } else if (isHelperTurn) {
    order = env.HELPER_PROVIDER_ORDER || "glm";
  } else {
    order = env.TEXT_PROVIDER_ORDER || "claude,glm";
  }
  const providers: ChatProvider[] = [];
  for (const name of order.split(",").map((part) => part.trim().toLowerCase())) {
    const provider = available[name];
    if (provider && !providers.includes(provider)) providers.push(provider);
  }
  return providers;
}

/** Asks the paid providers in turn; undefined when none is set or none answered. */
async function answerWithPaidProviders(
  env: Env,
  geminiBody: Record<string, unknown>,
  streaming: boolean,
  routeName: string,
  forcedOrder?: string
): Promise<Response | undefined> {
  for (const provider of paidProviders(env, geminiBody, routeName === "/gemini", forcedOrder)) {
    // Screen jobs send a screenshot every step: only the newest ones go.
    const fittedBody = fittedForProvider(provider, geminiBody, routeName === "/chat");
    if (!canAnswer(provider, fittedBody)) {
      console.warn(`[${routeName}] too big for ${provider.name}`);
      continue;
    }
    const response = await answerWithProvider(provider, fittedBody, streaming);
    if (response) return response;
    console.warn(`[${routeName}] ${provider.name} couldn't answer`);
  }
  return undefined;
}

/** Groq's small talk models, cheapest first; text only, so no vision models. */
export const DEFAULT_GROQ_TALK_MODELS = "openai/gpt-oss-20b,qwen/qwen3.8-27b";

/**
 * Dottie's talker: Groq alone answers small talk or says the ask is a
 * request (the app then sends it to Claude). Never a paid model or Gemini,
 * so chatting costs next to nothing.
 */
async function answerTalk(env: Env, requestBody: Record<string, unknown>): Promise<Response> {
  if (!env.GROQ_API_KEY) return jsonResponse({ error: "talking needs GROQ_API_KEY" }, 503);
  const talkModels = env.GROQ_TALK_MODELS || DEFAULT_GROQ_TALK_MODELS;
  const groq = groqProvider(env.GROQ_API_KEY, talkModels, talkModels, env.GROQ_MAX_REQUEST_TOKENS);
  if (!canAnswer(groq, requestBody)) return jsonResponse({ error: "too big to talk about" }, 413);
  const groqResponse = await answerWithProvider(groq, requestBody, true);
  return groqResponse ?? jsonResponse({ error: "Groq couldn't answer" }, 503);
}

function groqFromEnv(env: Env): ChatProvider | undefined {
  return env.GROQ_API_KEY
    ? groqProvider(env.GROQ_API_KEY, env.GROQ_TEXT_MODELS, env.GROQ_VISION_MODELS, env.GROQ_MAX_REQUEST_TOKENS)
    : undefined;
}

/**
 * Gemini CLI's side of the Dots: it thinks it is talking to Gemini at
 * GOOGLE_GEMINI_BASE_URL, and this answers in Gemini's format with the
 * same models /chat uses. Model calls go to answerWithAnyProvider,
 * counting tokens is estimated here, and listing models lists the one
 * name the CLI is told to use, so nothing ever reaches Google.
 */
async function handleGeminiPassthrough(request: Request, url: URL, env: Env): Promise<Response> {
  const upstreamPath = url.pathname.slice("/gemini".length);
  if (request.method === "GET") {
    const singleModel = upstreamPath.match(/\/models\/([^/:]+)$/);
    const listedModel = (name: string) => ({ name: `models/${name}`, supportedGenerationMethods: ["generateContent", "countTokens"] });
    return singleModel
      ? jsonResponse(listedModel(decodeURIComponent(singleModel[1])))
      : jsonResponse({ models: [listedModel(DOTS_MODEL_NAME)] });
  }

  const geminiBody = await readJSONObject(request);
  if (!geminiBody) return geminiErrorResponse(400, "INVALID_ARGUMENT", "the body must be a JSON object");

  const method = upstreamPath.slice(upstreamPath.lastIndexOf(":") + 1);
  if (method === "countTokens") {
    // Gemini CLI asks before squeezing a long chat; an estimate is enough.
    const countedBody = (geminiBody.generateContentRequest as Record<string, unknown> | undefined) ?? geminiBody;
    return jsonResponse({ totalTokens: estimatedTokens(countedBody) });
  }

  const answer = await answerWithAnyProvider(env, geminiBody, method === "streamGenerateContent", "/gemini");
  return answer ?? geminiErrorResponse(503, "UNAVAILABLE", NO_MODEL_ANSWERED_MESSAGE);
}

/** The model name Gemini CLI is started with (GeminiCLIAgentRuntime.defaultAgentModel); only a label now. */
const DOTS_MODEL_NAME = "gemini-3.6-flash";

/** An error the way Gemini's API writes one, so Gemini CLI shows the message. */
function geminiErrorResponse(code: number, status: string, message: string): Response {
  return jsonResponse({ error: { code, status, message } }, code);
}
