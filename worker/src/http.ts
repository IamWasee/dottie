/** Small response and request helpers shared by every route. */

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/**
 * The request's body as a JSON object, or undefined when it isn't one
 * (empty, not JSON, or a JSON array, string or number).
 */
export async function readJSONObject(request: Request): Promise<Record<string, unknown> | undefined> {
  const parsedBody: unknown = await request.json().catch(() => undefined);
  if (!parsedBody || typeof parsedBody !== "object" || Array.isArray(parsedBody)) return undefined;
  return parsedBody as Record<string, unknown>;
}

/**
 * Passes an upstream error on as it is (same status, same body) after
 * logging it, so the app can show what the provider said.
 */
export async function upstreamErrorResponse(routeLabel: string, upstreamResponse: Response): Promise<Response> {
  const errorBody = await upstreamResponse.text();
  console.error(`[${routeLabel}] upstream error ${upstreamResponse.status}: ${errorBody}`);
  return new Response(errorBody, {
    status: upstreamResponse.status,
    headers: { "content-type": "application/json" },
  });
}

/**
 * True when both strings are the same, taking the same time whether they
 * differ at the first character or the last, so a caller can't find a
 * secret one character at a time by timing answers.
 */
export function isSameSecret(presented: string, expected: string): boolean {
  const presentedBytes = new TextEncoder().encode(presented);
  const expectedBytes = new TextEncoder().encode(expected);
  let difference = presentedBytes.length ^ expectedBytes.length;
  for (let index = 0; index < expectedBytes.length; index += 1) {
    difference |= (presentedBytes[index] ?? 0) ^ expectedBytes[index];
  }
  return difference === 0;
}
