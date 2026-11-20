/**
 * Jev, TypeSafe's System One model (docs.typesafe.ai): it answers fixed
 * questions about a state, text and screenshots, as yes/no, one choice, a
 * score or a box around something. Dottie uses it to find what to click
 * ("the first email") and to check whether a screen job is done; it writes
 * no text and plans nothing. The app sends a System One request body; the
 * Worker adds the key (JEV_API_KEY) and the header pictures need.
 */
import { jsonResponse, readJSONObject } from "./http";

export const JEV_API_URL = "https://api.typesafe.ai/v1/systemone";
/** Jev's alias for its newest model (box questions need 1.14 or newer). */
export const DEFAULT_JEV_MODEL = "jev-latest";
/** Jev is a one-decision model; a slow answer is worth no more than a model's. */
const JEV_TIMEOUT_MILLISECONDS = 20_000;

/** The body as Jev takes it, or a reason it can't be sent. */
export function jevRequestBody(body: Record<string, unknown>, defaultModel = DEFAULT_JEV_MODEL): Record<string, unknown> | string {
  const questions = body.questions;
  if (!questions || typeof questions !== "object" || Array.isArray(questions) || Object.keys(questions).length === 0) {
    return "questions must be an object with at least one question";
  }
  if (body.state === undefined) return "state is missing";
  return { ...body, model: typeof body.model === "string" && body.model ? body.model : defaultModel };
}

/** True when the body carries pictures, which Jev only takes with its images header. */
export function hasImageAssets(body: Record<string, unknown>): boolean {
  const assets = body.assets;
  if (!assets || typeof assets !== "object") return false;
  return Object.values(assets as Record<string, unknown>).some(
    (asset) => Boolean(asset) && typeof asset === "object" && (asset as Record<string, unknown>).type === "image"
  );
}

/** True when a question asks for a box, which needs the images header too. */
function asksForABox(body: Record<string, unknown>): boolean {
  return Object.values(body.questions as Record<string, unknown>).some(
    (question) => Boolean(question) && typeof question === "object" && (question as Record<string, unknown>).type === "box"
  );
}

export async function handleJev(request: Request, apiKey: string | undefined, model: string | undefined): Promise<Response> {
  if (!apiKey) return jsonResponse({ error: "Jev isn't set up on this Worker" }, 503);
  const incomingBody = await readJSONObject(request);
  if (!incomingBody) return jsonResponse({ error: "the body must be a JSON object" }, 400);
  const jevBody = jevRequestBody(incomingBody, model || DEFAULT_JEV_MODEL);
  if (typeof jevBody === "string") return jsonResponse({ error: jevBody }, 400);

  const headers: Record<string, string> = {
    authorization: `Bearer ${apiKey}`,
    "content-type": "application/json",
  };
  if (hasImageAssets(jevBody) || asksForABox(jevBody)) headers["TypeSafe-Danger-Zone-Images"] = "true";

  let response: Response;
  try {
    response = await fetch(JEV_API_URL, {
      method: "POST",
      headers,
      body: JSON.stringify(jevBody),
      signal: AbortSignal.timeout(JEV_TIMEOUT_MILLISECONDS),
    });
  } catch (error) {
    console.warn(`[/jev] Jev didn't answer: ${error}`);
    return jsonResponse({ error: "Jev didn't answer in time" }, 504);
  }
  const answerText = await response.text();
  if (!response.ok) console.warn(`[/jev] Jev answered ${response.status}: ${answerText.slice(0, 300)}`);
  return new Response(answerText, {
    status: response.status,
    headers: { "content-type": response.headers.get("content-type") ?? "application/json" },
  });
}
