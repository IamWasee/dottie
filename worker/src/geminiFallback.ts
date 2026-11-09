/**
 * Trying Gemini's models in turn: which ones, how long each may take to
 * start answering, and the calls themselves.
 */

export const GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta";

/** Statuses that mean "busy or over its limit": the next model gets a turn. */
export const BUSY_STATUSES = [429, 500, 503, 504];

/** The chosen model first, then the fallbacks, without repeats. */
export function modelsToTry(model: string, fallbackModels?: string): string[] {
  const fallbacks = (fallbackModels ?? "").split(",").map((name) => name.trim()).filter(Boolean);
  return [...new Set([model, ...fallbacks])];
}

/**
 * `x-dottie-attempt-seconds`: how long one model may take to start
 * answering before the next one is tried. The app sends it for quick
 * lookups (a box on a screenshot), where a model that's slow to start
 * would otherwise use up the whole wait before a fallback gets a turn
 * (Oct 2026: busy models took 30-160 s to fail). Without it, each model
 * gets as long as it needs.
 */
export function attemptTimeoutMilliseconds(request: Request): number | undefined {
  const attemptSeconds = Number(request.headers.get("x-dottie-attempt-seconds"));
  if (!Number.isFinite(attemptSeconds) || attemptSeconds <= 0) return undefined;
  return Math.min(attemptSeconds, 60) * 1000;
}

/**
 * Calls `models/<model>:<method>` on each model in turn until one answers.
 * Free-tier models often say "high demand" (503) or hit their per-model
 * limit (429) while others are fine, so a busy model moves on to the next.
 * Any other error is returned as is.
 */
export async function fetchGeminiWithFallback(
  geminiAPIKey: string,
  models: string[],
  method: string,
  body: string,
  attemptTimeoutMs?: number
): Promise<Response> {
  let response: Response | undefined;
  for (const [index, model] of models.entries()) {
    const isLastModel = index === models.length - 1;
    // Only waiting for the answer to start is timed: once it streams, it
    // runs to the end. The last model gets as long as it needs, since
    // there's nothing left to try.
    const attemptAbort = attemptTimeoutMs && !isLastModel ? new AbortController() : undefined;
    const attemptTimer = attemptAbort ? setTimeout(() => attemptAbort.abort(), attemptTimeoutMs) : undefined;
    try {
      response = await fetch(`${GEMINI_API_BASE}/models/${encodeURIComponent(model)}:${method}`, {
        method: "POST",
        headers: {
          "x-goog-api-key": geminiAPIKey,
          "content-type": "application/json",
        },
        body,
        signal: attemptAbort?.signal,
      });
    } catch (error) {
      if (!attemptAbort?.signal.aborted) throw error;
      console.warn(`${model} didn't start answering within ${attemptTimeoutMs} ms; trying ${models[index + 1]}`);
      continue;
    } finally {
      if (attemptTimer !== undefined) clearTimeout(attemptTimer);
    }
    const isBusy = BUSY_STATUSES.includes(response.status);
    if (!isBusy || index === models.length - 1) break;
    console.warn(`${model} answered ${response.status}; trying ${models[index + 1]}`);
    await response.body?.cancel();
  }
  return response!;
}
