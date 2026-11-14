/**
 * GET /search: web search without Google Search grounding (free-tier keys
 * can't use it). See handleSearch.
 */

import { jsonResponse } from "./http";

export interface SearchResult {
  title: string;
  url: string;
  snippet: string;
}

/**
 * Web search for a free-tier key, which gets "You exceeded your current
 * quota" for Gemini's Google Search tool. Asks Bing (its results page and
 * its RSS feed) and DuckDuckGo at once and keeps the answer that covers
 * the most of the query's words, falling back to Wikipedia when none
 * does. Bing often answers server addresses with results for one word
 * of the query ("weather in london today" gave Detroit's
 * weather, "who won the 2025 world series" gave dictionary pages for
 * "won"), so the first engine with any results isn't trusted on its own.
 * Adds Roblox's own search for Roblox games, and the readable text of the
 * first result so a short answer needs no second call. `debug=1` adds
 * what each engine returned.
 */
export async function handleSearch(url: URL): Promise<Response> {
  const query = (url.searchParams.get("q") ?? "").trim().slice(0, 300);
  if (!query) {
    return jsonResponse({ error: "missing q" }, 400);
  }

  const queryWords = meaningfulQueryWords(query);
  const engineAnswers: { engineName: string; results: SearchResult[]; coverage: number }[] = [];
  async function askEngine(engineName: string, searchEngine: (query: string) => Promise<SearchResult[]>) {
    const engineResults = await searchEngine(query).catch(() => [] as SearchResult[]);
    engineAnswers.push({ engineName, results: engineResults, coverage: queryWordCoverage(queryWords, engineResults) });
  }

  await Promise.all([
    askEngine("bing", searchBing),
    askEngine("bing-rss", searchBingFeed),
    askEngine("duckduckgo", searchDuckDuckGo),
  ]);
  if (!engineAnswers.some((answer) => answer.coverage >= GOOD_QUERY_COVERAGE)) {
    await askEngine("wikipedia", searchWikipedia);
  }

  // The answer covering the most of the query wins; on a tie, the engine
  // asked first (Bing's page has the best snippets).
  const engineOrder = ["bing", "bing-rss", "duckduckgo", "wikipedia"];
  const bestAnswer = engineAnswers
    .filter((answer) => answer.results.length > 0)
    .sort((first, second) =>
      second.coverage - first.coverage || engineOrder.indexOf(first.engineName) - engineOrder.indexOf(second.engineName)
    )[0];
  let results = bestAnswer?.results ?? [];
  let source = bestAnswer?.engineName ?? "";

  // Roblox experiences are often too new or small for the web engines, but
  // Roblox's own search has the game and its description.
  if (/\broblox\b/i.test(query)) {
    const robloxGame = await searchRobloxGame(query).catch(() => undefined);
    if (robloxGame) {
      results = [robloxGame, ...results].slice(0, 6);
      source = source ? `roblox+${source}` : "roblox";
    }
  }

  let topPage: { url: string; text: string } | undefined;
  for (const result of results.slice(0, 2)) {
    const text = await fetchReadableText(result.url).catch(() => "");
    if (text.length > 200) {
      topPage = { url: result.url, text };
      break;
    }
  }

  const searchAnswer: Record<string, unknown> = { query, source, results, topPage };
  if (url.searchParams.get("debug") === "1") {
    searchAnswer.engines = engineAnswers.map((answer) => ({
      engine: answer.engineName,
      count: answer.results.length,
      coverage: Math.round(answer.coverage * 100) / 100,
      titles: answer.results.slice(0, 3).map((result) => result.title),
    }));
  }
  return jsonResponse(searchAnswer);
}

/** Share of the query's words an engine's results must mention to be trusted without asking Wikipedia. */
const GOOD_QUERY_COVERAGE = 0.6;

const QUERY_FILLER_WORDS = new Set([
  "a", "an", "the", "of", "in", "on", "at", "to", "for", "and", "or", "is", "are", "was", "were", "be",
  "what", "whats", "who", "whos", "when", "where", "why", "how", "which", "does", "do", "did", "can",
  "me", "my", "i", "you", "it", "this", "that", "tell", "about", "please", "now", "today", "current", "latest",
]);

export function meaningfulQueryWords(query: string): string[] {
  const words = query.toLowerCase().replace(/[^\p{L}\p{N}\s]/gu, " ").split(/\s+/).filter(Boolean);
  const meaningfulWords = words.filter((word) => !QUERY_FILLER_WORDS.has(word));
  return [...new Set(meaningfulWords.length > 0 ? meaningfulWords : words)];
}

/** How many of the query's words (0 to 1) show up in the first three results' titles and snippets. */
export function queryWordCoverage(queryWords: string[], results: SearchResult[]): number {
  if (queryWords.length === 0 || results.length === 0) return 0;
  const resultText = results
    .slice(0, 3)
    .map((result) => `${result.title} ${result.snippet} ${result.url}`)
    .join(" ")
    .toLowerCase();
  const mentionedWordCount = queryWords.filter((word) => resultText.includes(word)).length;
  return mentionedWordCount / queryWords.length;
}

const BROWSER_HEADERS = {
  "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36",
  "accept-language": "en-US,en;q=0.9",
  // Without a browser's accept header, Bing often searches for just one
  // word of the query.
  "accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
};

export async function searchBing(query: string): Promise<SearchResult[]> {
  const response = await fetch(
    `https://www.bing.com/search?q=${encodeURIComponent(query)}&setlang=en&cc=US`,
    { headers: BROWSER_HEADERS, signal: AbortSignal.timeout(6000) }
  );
  if (!response.ok) return [];
  const html = await response.text();

  const results: SearchResult[] = [];
  for (const resultBlock of html.split('<li class="b_algo"').slice(1)) {
    const titleLink = resultBlock.match(/<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/);
    if (!titleLink) continue;
    let resultURL = decodeHTMLEntities(titleLink[1]);
    // Bing wraps links as /ck/a?...&u=a1<base64url of the real address>.
    const wrappedTarget = resultURL.match(/[?&]u=a1([^&]+)/);
    if (wrappedTarget) {
      const base64 = wrappedTarget[1].replace(/-/g, "+").replace(/_/g, "/");
      try {
        resultURL = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
      } catch {
        continue;
      }
    }
    if (!resultURL.startsWith("http")) continue;
    const snippet = resultBlock.match(/<p[^>]*>([\s\S]*?)<\/p>/);
    results.push({ title: htmlToText(titleLink[2]), url: resultURL, snippet: snippet ? htmlToText(snippet[1]) : "" });
    if (results.length === 6) break;
  }
  return results;
}

/** Bing's RSS feed of the same search: plain links, served even when the results page is cut down. */
export async function searchBingFeed(query: string): Promise<SearchResult[]> {
  const response = await fetch(
    `https://www.bing.com/search?format=rss&q=${encodeURIComponent(query)}&setlang=en&mkt=en-US`,
    { headers: BROWSER_HEADERS, signal: AbortSignal.timeout(6000) }
  );
  if (!response.ok) return [];
  const feed = await response.text();

  const results: SearchResult[] = [];
  for (const item of feed.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    const title = item[1].match(/<title>([\s\S]*?)<\/title>/)?.[1] ?? "";
    const link = item[1].match(/<link>([\s\S]*?)<\/link>/)?.[1] ?? "";
    const description = item[1].match(/<description>([\s\S]*?)<\/description>/)?.[1] ?? "";
    const resultURL = decodeHTMLEntities(link.trim());
    if (!resultURL.startsWith("http")) continue;
    results.push({ title: htmlToText(title), url: resultURL, snippet: htmlToText(decodeHTMLEntities(description)) });
    if (results.length === 6) break;
  }
  return results;
}

/** The best-matching Roblox experience and its description, from Roblox's own search. */
export async function searchRobloxGame(query: string): Promise<SearchResult | undefined> {
  const gameName = query
    .replace(/\b(roblox|guide|how to play|wiki|beginner|tips)\b/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!gameName) return undefined;
  const searchResponse = await fetch(
    `https://apis.roblox.com/search-api/omni-search?searchQuery=${encodeURIComponent(gameName)}&pageType=all&sessionId=${crypto.randomUUID()}`,
    { headers: BROWSER_HEADERS, signal: AbortSignal.timeout(6000) }
  );
  if (!searchResponse.ok) return undefined;
  const searchPayload = (await searchResponse.json()) as {
    searchResults?: { contentGroupType?: string; contents?: { universeId?: number; rootPlaceId?: number; name?: string; description?: string }[] }[];
  };
  const firstGame = (searchPayload.searchResults ?? [])
    .filter((group) => group.contentGroupType === "Game")
    .flatMap((group) => group.contents ?? [])
    .find((game) => game.universeId && game.name);
  if (!firstGame?.universeId || !firstGame.name) return undefined;

  let description = firstGame.description ?? "";
  if (!description) {
    const detailsResponse = await fetch(`https://games.roblox.com/v1/games?universeIds=${firstGame.universeId}`, {
      headers: BROWSER_HEADERS,
      signal: AbortSignal.timeout(6000),
    });
    if (detailsResponse.ok) {
      const detailsPayload = (await detailsResponse.json()) as { data?: { description?: string }[] };
      description = detailsPayload.data?.[0]?.description ?? "";
    }
  }
  return {
    title: `${firstGame.name} (Roblox experience)`,
    url: firstGame.rootPlaceId ? `https://www.roblox.com/games/${firstGame.rootPlaceId}` : "https://www.roblox.com/discover",
    snippet: `The game's own description on Roblox: ${description.replace(/\s+/g, " ").slice(0, 1500)}`,
  };
}

export async function searchDuckDuckGo(query: string): Promise<SearchResult[]> {
  // A form post, like the page's own search box; plain GETs from servers
  // get a 202 challenge page more often.
  const response = await fetch("https://html.duckduckgo.com/html/", {
    method: "POST",
    headers: { ...BROWSER_HEADERS, "content-type": "application/x-www-form-urlencoded" },
    body: `q=${encodeURIComponent(query)}&kl=us-en`,
    signal: AbortSignal.timeout(6000),
  });
  if (!response.ok) return [];
  const html = await response.text();

  const results: SearchResult[] = [];
  const resultPattern =
    /class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>[\s\S]*?class="result__snippet"[^>]*>([\s\S]*?)<\/a>/g;
  for (const match of html.matchAll(resultPattern)) {
    let resultURL = decodeHTMLEntities(match[1]);
    const redirectTarget = resultURL.match(/[?&]uddg=([^&]+)/);
    if (redirectTarget) resultURL = decodeURIComponent(redirectTarget[1]);
    if (resultURL.startsWith("//")) resultURL = "https:" + resultURL;
    // Skip DuckDuckGo's own ads.
    if (!resultURL.startsWith("http") || resultURL.includes("duckduckgo.com/y.js")) continue;
    results.push({ title: htmlToText(match[2]), url: resultURL, snippet: htmlToText(match[3]) });
    if (results.length === 6) break;
  }
  return results;
}

export async function searchWikipedia(query: string): Promise<SearchResult[]> {
  const response = await fetch(
    `https://en.wikipedia.org/w/api.php?action=query&list=search&format=json&srlimit=5&srsearch=${encodeURIComponent(query)}`,
    { headers: { "user-agent": "Dottie/1.0 (https://github.com/IamWasee/dottie)" }, signal: AbortSignal.timeout(6000) }
  );
  if (!response.ok) return [];
  const payload = (await response.json()) as { query?: { search?: { title: string; snippet: string }[] } };
  return (payload.query?.search ?? []).map((page) => ({
    title: page.title,
    url: `https://en.wikipedia.org/wiki/${encodeURIComponent(page.title.replace(/ /g, "_"))}`,
    snippet: htmlToText(page.snippet),
  }));
}

/** How much of a page is read for its text. The answer is in the first part; the rest is never downloaded. */
const MAXIMUM_PAGE_BYTES = 600_000;

/**
 * The start of a response's body as text. Reading stops at the limit, so a
 * page of any size (or one that never ends) costs no more than the limit.
 */
export async function readTextUpTo(response: Response, maximumBytes: number): Promise<string> {
  if (!response.body) return "";
  const bodyReader = response.body.getReader();
  const textDecoder = new TextDecoder();
  let text = "";
  let receivedBytes = 0;
  while (receivedBytes < maximumBytes) {
    const { done, value } = await bodyReader.read();
    if (done) break;
    const bytesToKeep = value.subarray(0, maximumBytes - receivedBytes);
    receivedBytes += bytesToKeep.byteLength;
    text += textDecoder.decode(bytesToKeep, { stream: true });
  }
  await bodyReader.cancel().catch(() => {});
  return text + textDecoder.decode();
}

/** The page's visible text, without scripts, styles and markup, cut to about 2500 characters (the answer is near the top, and every character is read again by the model). */
export async function fetchReadableText(pageURL: string): Promise<string> {
  const response = await fetch(pageURL, { headers: BROWSER_HEADERS, signal: AbortSignal.timeout(6000) });
  const contentType = response.headers.get("content-type") ?? "";
  if (!response.ok || !contentType.includes("html")) return "";
  const html = await readTextUpTo(response, MAXIMUM_PAGE_BYTES);
  const body = html
    .replace(/<(script|style|noscript|svg|nav|footer|header|form)[\s\S]*?<\/\1>/gi, " ")
    .replace(/<!--[\s\S]*?-->/g, " ");
  return htmlToText(body).slice(0, 2500);
}

export function htmlToText(html: string): string {
  return decodeHTMLEntities(html.replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ").trim();
}

export function decodeHTMLEntities(text: string): string {
  return text
    .replace(/&#x([0-9a-f]+);/gi, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, decimal) => String.fromCodePoint(parseInt(decimal, 10)))
    .replace(/&quot;/g, '"')
    .replace(/&apos;|&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&");
}
