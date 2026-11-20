/**
 * Limits per install: how much one copy of Dottie may ask for in a day.
 *
 * Every copy of the app makes up an install id the first time it runs and
 * sends it with each request (the `x-dottie-install` header, or the end of
 * the "API key" Gemini CLI sends). The Worker counts each install's
 * requests per area and per day in a small Durable Object, and turns the
 * install away for the rest of the day once an area is used up. A caller
 * that sends no install id is counted by its address instead.
 *
 * The shared secret keeps strangers out; these limits bound what one copy
 * of the app can spend, and how many new copies can show up in a day, so a
 * secret pulled out of a download can't be used to spend without end.
 *
 * Without the INSTALL_USAGE binding nothing is counted, and a counter that
 * fails never blocks anyone.
 */

import { jsonResponse } from "./http";

/** The slice of the Worker's settings the limits read. */
export interface UsageLimitSettings {
  INSTALL_USAGE?: DurableObjectNamespace;
  /** "voice=300,chat=3000,…": the day's limit per area; areas left out keep the defaults. */
  INSTALL_DAILY_LIMITS?: string;
  /** Comma-separated install ids that are never limited (the owner's own Macs). */
  UNLIMITED_INSTALL_IDS?: string;
}

export type UsageArea = "voice" | "chat" | "speech" | "dictation" | "helpers" | "search";

/** One more than any area: how many installs the Worker has never seen before may start in a day. */
type LimitName = UsageArea | "newInstalls";

export const DEFAULT_DAILY_LIMITS: Record<LimitName, number> = {
  voice: 300,
  chat: 3000,
  speech: 1000,
  dictation: 1000,
  helpers: 3000,
  search: 1000,
  newInstalls: 200,
};

/** What the user is told is used up, per area. */
const AREA_WORDS: Record<UsageArea, string> = {
  voice: "voice sessions",
  chat: "questions and screen work",
  speech: "spoken answers",
  dictation: "dictation",
  helpers: "helper work",
  search: "web searches",
};

const INSTALL_ID_PATTERN = /^[A-Za-z0-9-]{16,64}$/;
const KEY_WITH_INSTALL_ID_PATTERN = /^(.*):([A-Za-z0-9-]{16,64})$/;

/** The area a request counts toward, or undefined for requests that cost nothing (health, config, the phone). */
export function usageArea(method: string, pathname: string): UsageArea | undefined {
  if (pathname.startsWith("/gemini/") || pathname.startsWith("/gemini-only/")) return method === "POST" ? "helpers" : undefined;
  if (method === "GET" && pathname === "/search") return "search";
  if (method !== "POST") return undefined;
  if (pathname === "/chat" || pathname === "/jev") return "chat";
  return undefined;
}

/** The day's limits: the defaults, with any "area=number" pairs from the setting on top. */
export function dailyLimits(limitsSetting: string | undefined): Record<LimitName, number> {
  const limits = { ...DEFAULT_DAILY_LIMITS };
  for (const pair of (limitsSetting ?? "").split(",")) {
    const [name, value] = pair.split("=").map((part) => part.trim());
    const limit = Number(value);
    if (name in limits && value !== "" && Number.isInteger(limit) && limit >= 0) limits[name as LimitName] = limit;
  }
  return limits;
}

/**
 * Splits the "API key" Gemini CLI sends into the shared secret and the
 * install id the app put after it ("secret:install-id"). A key without an
 * install id comes back whole.
 */
export function splitPassthroughKey(sentKey: string): { secret: string; installID?: string } {
  const match = sentKey.match(KEY_WITH_INSTALL_ID_PATTERN);
  return match ? { secret: match[1], installID: match[2] } : { secret: sentKey };
}

/** Who a request is counted against: its install id when it sends a believable one, else its address. */
export function usageIdentity(request: Request, url: URL): string {
  const headerInstallID = request.headers.get("x-dottie-install") ?? "";
  if (INSTALL_ID_PATTERN.test(headerInstallID)) return `install:${headerInstallID}`;
  const keyInstallID = splitPassthroughKey(request.headers.get("x-goog-api-key") ?? url.searchParams.get("key") ?? "").installID;
  if (keyInstallID) return `install:${keyInstallID}`;
  return `address:${request.headers.get("cf-connecting-ip") ?? "unknown"}`;
}

function secondsUntilNextDay(now: Date): number {
  const nextDay = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1);
  return Math.max(1, Math.ceil((nextDay - now.getTime()) / 1000));
}

/**
 * Counts this request, and answers with the refusal to send back when the
 * install has used up the area for today (or is new on a day that already
 * took in its share of new installs). Undefined means go ahead.
 */
export async function usageRefusal(request: Request, url: URL, settings: UsageLimitSettings): Promise<Response | undefined> {
  const area = usageArea(request.method, url.pathname);
  if (!area || !settings.INSTALL_USAGE) return undefined;

  const identity = usageIdentity(request, url);
  const unlimitedInstallIDs = (settings.UNLIMITED_INSTALL_IDS ?? "").split(",").map((installID) => installID.trim()).filter(Boolean);
  if (unlimitedInstallIDs.some((installID) => identity === `install:${installID}`)) return undefined;

  const limits = dailyLimits(settings.INSTALL_DAILY_LIMITS);
  const now = new Date();
  let verdict: { allowed: boolean; reason?: string };
  try {
    const counter = settings.INSTALL_USAGE.get(settings.INSTALL_USAGE.idFromName(identity));
    const counterResponse = await counter.fetch("https://install-usage/count", {
      method: "POST",
      body: JSON.stringify({ area, limit: limits[area], newInstallLimit: limits.newInstalls, day: now.toISOString().slice(0, 10) }),
    });
    verdict = await counterResponse.json();
  } catch (error) {
    console.warn(`[usage] the counter failed: ${error}`);
    return undefined;
  }
  if (verdict.allowed) return undefined;

  const message =
    verdict.reason === "newInstalls"
      ? "Dottie isn't taking new installs today. Try again tomorrow."
      : `That's today's limit for ${AREA_WORDS[area]}. It starts over at midnight UTC.`;
  return new Response(JSON.stringify({ error: message, limit: verdict.reason ?? area }), {
    status: 429,
    headers: { "content-type": "application/json", "retry-after": String(secondsUntilNextDay(now)) },
  });
}

/**
 * The counters. One object per install holds that install's counts for
 * the current day; the object named "directory" counts how many installs
 * were seen for the first time today.
 */
export class InstallUsage {
  constructor(private state: DurableObjectState, private settings: UsageLimitSettings) {}

  async fetch(request: Request): Promise<Response> {
    const body = await request.json<{ area?: string; limit?: number; newInstallLimit?: number; day?: string }>().catch(() => ({}) as Record<string, undefined>);
    const storage = this.state.storage;
    const day = body.day ?? "";
    const limit = body.limit ?? 0;

    // A new day starts every count again; "known" (this install has been let in before) stays.
    if ((await storage.get<string>("day")) !== day) {
      const isKnown = await storage.get<boolean>("known");
      await storage.deleteAll();
      await storage.put("day", day);
      if (isKnown) await storage.put("known", true);
    }

    if (new URL(request.url).pathname === "/new-install") {
      const newInstallCount = (await storage.get<number>("newInstalls")) ?? 0;
      if (newInstallCount >= limit) return jsonResponse({ allowed: false });
      await storage.put("newInstalls", newInstallCount + 1);
      return jsonResponse({ allowed: true });
    }

    if (!(await storage.get<boolean>("known"))) {
      const directory = this.settings.INSTALL_USAGE?.get(this.settings.INSTALL_USAGE.idFromName("directory"));
      const directoryResponse = await directory?.fetch("https://install-usage/new-install", { method: "POST", body: JSON.stringify({ limit: body.newInstallLimit ?? 0, day }) });
      const directoryVerdict = (await directoryResponse?.json<{ allowed: boolean }>()) ?? { allowed: true };
      if (!directoryVerdict.allowed) return jsonResponse({ allowed: false, reason: "newInstalls" });
      await storage.put("known", true);
    }

    const areaKey = `count:${body.area ?? ""}`;
    const usedCount = (await storage.get<number>(areaKey)) ?? 0;
    if (usedCount >= limit) return jsonResponse({ allowed: false });
    await storage.put(areaKey, usedCount + 1);
    return jsonResponse({ allowed: true });
  }
}
