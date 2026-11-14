import { afterEach, describe, expect, it, vi } from "vitest";
import {
  decodeHTMLEntities,
  fetchReadableText,
  readTextUpTo,
  handleSearch,
  htmlToText,
  meaningfulQueryWords,
  queryWordCoverage,
  searchBing,
  searchBingFeed,
  searchDuckDuckGo,
  searchRobloxGame,
  searchWikipedia,
} from "../src/search";
import { fakeFetch, jsonAnswer } from "./helpers";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

const htmlAnswer = (html: string, status = 200) => new Response(html, { status, headers: { "content-type": "text/html; charset=utf-8" } });
const base64URL = (text: string) => btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** A Bing results page with these results, links wrapped the way Bing wraps them. */
function bingPage(results: { title: string; url: string; snippet?: string }[]): string {
  return `<html><body><ol>${results
    .map(
      (result) =>
        `<li class="b_algo"><h2 class="t"><a target="_blank" href="https://www.bing.com/ck/a?!&amp;&amp;p=abc&amp;u=a1${base64URL(result.url)}&amp;ntb=1">${result.title}</a></h2>${
          result.snippet === undefined ? "" : `<p class="b_lineclamp2">${result.snippet}</p>`
        }</li>`
    )
    .join("")}</ol></body></html>`;
}

function duckDuckGoPage(results: { title: string; url: string; snippet: string }[]): string {
  return results
    .map(
      (result) =>
        `<div class="result"><a rel="nofollow" class="result__a" href="${result.url}">${result.title}</a><a class="result__snippet" href="${result.url}">${result.snippet}</a></div>`
    )
    .join("\n");
}

function bingFeed(items: { title: string; link: string; description: string }[]): string {
  return `<rss><channel>${items.map((item) => `<item><title>${item.title}</title><link>${item.link}</link><description>${item.description}</description></item>`).join("")}</channel></rss>`;
}

const pageText = "The weather in London today is mild and cloudy with light rain later. ".repeat(6);

describe("decodeHTMLEntities", () => {
  it("decodes named, decimal and hex entities", () => {
    expect(decodeHTMLEntities("&lt;b&gt; &quot;Tom&quot; &amp; Jerry&apos;s &#39;x&#39; &#233; &#x1F600;&nbsp;end")).toBe("<b> \"Tom\" & Jerry's 'x' é 😀 end");
  });

  it("decodes &amp; last, so &amp;lt; stays text", () => {
    expect(decodeHTMLEntities("&amp;lt;")).toBe("&lt;");
  });

  it("leaves plain text and unknown entities alone", () => {
    expect(decodeHTMLEntities("plain &unknown; text")).toBe("plain &unknown; text");
  });
});

describe("htmlToText", () => {
  it("drops tags and squeezes spaces", () => {
    expect(htmlToText("<p>Hello   <b>world</b></p>\n<br/> again ")).toBe("Hello world again");
  });

  it("is empty for markup with no words", () => {
    expect(htmlToText("<div><span></span></div>")).toBe("");
  });
});

describe("meaningfulQueryWords", () => {
  it("drops filler words and punctuation, in lower case", () => {
    expect(meaningfulQueryWords("What's the weather in London today?")).toEqual(["s", "weather", "london"]);
  });

  it("keeps each word once", () => {
    expect(meaningfulQueryWords("roblox Roblox ROBLOX guide")).toEqual(["roblox", "guide"]);
  });

  it("keeps the filler words when nothing else is there", () => {
    expect(meaningfulQueryWords("who is it")).toEqual(["who", "is", "it"]);
  });

  it("keeps letters and digits from other alphabets", () => {
    expect(meaningfulQueryWords("café 2025 東京")).toEqual(["café", "2025", "東京"]);
  });

  it("is empty for an empty query", () => {
    expect(meaningfulQueryWords("  ?! ")).toEqual([]);
  });
});

describe("queryWordCoverage", () => {
  const result = (title: string, snippet = "", url = "https://example.com") => ({ title, snippet, url });

  it("is the share of words found in titles, snippets and addresses", () => {
    expect(queryWordCoverage(["weather", "london"], [result("London weather")])).toBe(1);
    expect(queryWordCoverage(["weather", "london"], [result("Detroit weather")])).toBe(0.5);
    expect(queryWordCoverage(["kaggle"], [result("Home", "", "https://kaggle.com")])).toBe(1);
  });

  it("only looks at the first three results", () => {
    const results = [result("a"), result("b"), result("c"), result("london")];
    expect(queryWordCoverage(["london"], results)).toBe(0);
  });

  it("is 0 without words or without results", () => {
    expect(queryWordCoverage([], [result("anything")])).toBe(0);
    expect(queryWordCoverage(["word"], [])).toBe(0);
  });
});

describe("searchBing", () => {
  it("reads titles, unwrapped links and snippets", async () => {
    const calls = fakeFetch([
      ["bing.com/search", htmlAnswer(bingPage([{ title: "London <strong>weather</strong>", url: "https://weather.example/london?a=1&b=2", snippet: "Mild &amp; cloudy" }]))],
    ]);
    expect(await searchBing("weather in london")).toEqual([{ title: "London weather", url: "https://weather.example/london?a=1&b=2", snippet: "Mild & cloudy" }]);
    expect(calls[0].url).toContain("q=weather%20in%20london");
    expect(calls[0].headers.get("user-agent")).toContain("Mozilla");
  });

  it("takes a plain link, skips blocks without one, and gives an empty snippet when there is none", async () => {
    const page =
      '<li class="b_algo"><div>no heading here</div></li>' +
      '<li class="b_algo"><h2><a href="https://plain.example/">Plain</a></h2></li>' +
      '<li class="b_algo"><h2><a href="/relative">Relative</a></h2></li>' +
      '<li class="b_algo"><h2><a href="https://www.bing.com/ck/a?u=a1%%%">Broken</a></h2></li>';
    fakeFetch([["bing.com/search", htmlAnswer(page)]]);
    expect(await searchBing("anything")).toEqual([{ title: "Plain", url: "https://plain.example/", snippet: "" }]);
  });

  it("stops at six results", async () => {
    const manyResults = Array.from({ length: 9 }, (_, index) => ({ title: `Result ${index}`, url: `https://example.com/${index}`, snippet: "s" }));
    fakeFetch([["bing.com/search", htmlAnswer(bingPage(manyResults))]]);
    expect(await searchBing("many")).toHaveLength(6);
  });

  it("is empty when Bing answers an error or a page without results", async () => {
    fakeFetch([["bing.com/search", htmlAnswer("blocked", 403)]]);
    expect(await searchBing("anything")).toEqual([]);
    fakeFetch([["bing.com/search", htmlAnswer("<html>captcha</html>")]]);
    expect(await searchBing("anything")).toEqual([]);
  });
});

describe("searchBingFeed", () => {
  it("reads items from the feed", async () => {
    const calls = fakeFetch([
      ["bing.com/search", htmlAnswer(bingFeed([{ title: "World Series 2025", link: " https://mlb.example/ws?x=1&amp;y=2 ", description: "The &lt;b&gt;Dodgers&lt;/b&gt; won" }]))],
    ]);
    expect(await searchBingFeed("who won")).toEqual([{ title: "World Series 2025", url: "https://mlb.example/ws?x=1&y=2", snippet: "The Dodgers won" }]);
    expect(calls[0].url).toContain("format=rss");
  });

  it("skips items without a web link and stops at six", async () => {
    const items = [{ title: "No link", link: "", description: "" }, ...Array.from({ length: 8 }, (_, index) => ({ title: `T${index}`, link: `https://e.com/${index}`, description: "d" }))];
    fakeFetch([["bing.com/search", htmlAnswer(bingFeed(items))]]);
    const results = await searchBingFeed("x");
    expect(results).toHaveLength(6);
    expect(results[0].title).toBe("T0");
  });

  it("handles an item with nothing in it, an error, and an empty feed", async () => {
    fakeFetch([["bing.com/search", htmlAnswer("<rss><item></item></rss>")]]);
    expect(await searchBingFeed("x")).toEqual([]);
    fakeFetch([["bing.com/search", htmlAnswer("", 500)]]);
    expect(await searchBingFeed("x")).toEqual([]);
    fakeFetch([["bing.com/search", htmlAnswer("<rss></rss>")]]);
    expect(await searchBingFeed("x")).toEqual([]);
  });
});

describe("searchDuckDuckGo", () => {
  it("posts the query like the page's own form and reads the results", async () => {
    const calls = fakeFetch([
      [
        "html.duckduckgo.com",
        htmlAnswer(
          duckDuckGoPage([
            { title: "Kaggle <b>RSNA</b>", url: "//duckduckgo.com/l/?uddg=https%3A%2F%2Fkaggle.com%2Fc%2Frsna&amp;rut=abc", snippet: "The RSNA competition" },
            { title: "Direct", url: "https://direct.example/page", snippet: "Direct link" },
            { title: "Protocol-relative", url: "//relative.example/page", snippet: "No scheme" },
          ])
        ),
      ],
    ]);
    expect(await searchDuckDuckGo("kaggle rsna")).toEqual([
      { title: "Kaggle RSNA", url: "https://kaggle.com/c/rsna", snippet: "The RSNA competition" },
      { title: "Direct", url: "https://direct.example/page", snippet: "Direct link" },
      { title: "Protocol-relative", url: "https://relative.example/page", snippet: "No scheme" },
    ]);
    expect(calls[0].method).toBe("POST");
    expect(calls[0].bodyText).toBe("q=kaggle%20rsna&kl=us-en");
  });

  it("skips ads and links that aren't web addresses, and stops at six", async () => {
    const results = [
      { title: "Ad", url: "https://duckduckgo.com/y.js?ad=1", snippet: "ad" },
      { title: "Script", url: "javascript:void(0)", snippet: "x" },
      ...Array.from({ length: 8 }, (_, index) => ({ title: `R${index}`, url: `https://e.com/${index}`, snippet: "s" })),
    ];
    fakeFetch([["html.duckduckgo.com", htmlAnswer(duckDuckGoPage(results))]]);
    const found = await searchDuckDuckGo("x");
    expect(found).toHaveLength(6);
    expect(found[0].title).toBe("R0");
  });

  it("is empty for an error or a challenge page", async () => {
    fakeFetch([["html.duckduckgo.com", htmlAnswer("", 500)]]);
    expect(await searchDuckDuckGo("x")).toEqual([]);
    fakeFetch([["html.duckduckgo.com", htmlAnswer("<html>Are you a robot?</html>", 200)]]);
    expect(await searchDuckDuckGo("x")).toEqual([]);
  });
});

describe("searchWikipedia", () => {
  it("turns pages into results with their addresses", async () => {
    const calls = fakeFetch([
      ["wikipedia.org", jsonAnswer({ query: { search: [{ title: "Roblox Studio", snippet: 'A <span class="searchmatch">game</span> engine' }] } })],
    ]);
    expect(await searchWikipedia("roblox studio")).toEqual([{ title: "Roblox Studio", url: "https://en.wikipedia.org/wiki/Roblox_Studio", snippet: "A game engine" }]);
    expect(calls[0].headers.get("user-agent")).toContain("Dottie");
  });

  it("is empty for an error or an answer with no pages", async () => {
    fakeFetch([["wikipedia.org", jsonAnswer({}, 503)]]);
    expect(await searchWikipedia("x")).toEqual([]);
    fakeFetch([["wikipedia.org", jsonAnswer({})]]);
    expect(await searchWikipedia("x")).toEqual([]);
  });
});

describe("searchRobloxGame", () => {
  const omniSearch = (contents: unknown[]) => jsonAnswer({ searchResults: [{ contentGroupType: "User", contents: [{ universeId: 1, name: "a person" }] }, { contentGroupType: "Game", contents }] });

  it("finds the game and uses its description", async () => {
    const calls = fakeFetch([["apis.roblox.com", omniSearch([{ universeId: 77, rootPlaceId: 99, name: "Grow a Garden", description: "Plant   seeds\nand sell crops." }])]]);
    expect(await searchRobloxGame("roblox grow a garden guide")).toEqual({
      title: "Grow a Garden (Roblox experience)",
      url: "https://www.roblox.com/games/99",
      snippet: "The game's own description on Roblox: Plant seeds and sell crops.",
    });
    expect(calls[0].url).toContain("searchQuery=grow%20a%20garden");
  });

  it("asks for the description when the search has none, and links to Discover without a place", async () => {
    const calls = fakeFetch([
      ["apis.roblox.com", omniSearch([{ universeId: 77, name: "Steal a Fish" }])],
      ["games.roblox.com", jsonAnswer({ data: [{ description: "Catch fish." }] })],
    ]);
    expect(await searchRobloxGame("roblox steal a fish")).toEqual({
      title: "Steal a Fish (Roblox experience)",
      url: "https://www.roblox.com/discover",
      snippet: "The game's own description on Roblox: Catch fish.",
    });
    expect(calls[1].url).toContain("universeIds=77");
  });

  it("gives an empty description when the details can't be read", async () => {
    fakeFetch([
      ["apis.roblox.com", omniSearch([{ universeId: 77, name: "Quiet Game" }])],
      ["games.roblox.com", jsonAnswer({}, 500)],
    ]);
    expect((await searchRobloxGame("roblox quiet game"))!.snippet).toBe("The game's own description on Roblox: ");
    fakeFetch([
      ["apis.roblox.com", omniSearch([{ universeId: 77, name: "Quiet Game" }])],
      ["games.roblox.com", jsonAnswer({ data: [] })],
    ]);
    expect((await searchRobloxGame("roblox quiet game"))!.snippet).toBe("The game's own description on Roblox: ");
  });

  it("is undefined when the query is only filler, the search fails, or no game matches", async () => {
    const calls = fakeFetch([]);
    expect(await searchRobloxGame("roblox guide tips")).toBeUndefined();
    expect(calls).toHaveLength(0);
    fakeFetch([["apis.roblox.com", jsonAnswer({}, 429)]]);
    expect(await searchRobloxGame("roblox something")).toBeUndefined();
    fakeFetch([["apis.roblox.com", jsonAnswer({})]]);
    expect(await searchRobloxGame("roblox something")).toBeUndefined();
    fakeFetch([["apis.roblox.com", omniSearch([{ name: "No id" }, { universeId: 5 }])]]);
    expect(await searchRobloxGame("roblox something")).toBeUndefined();
  });
});

describe("fetchReadableText", () => {
  it("keeps the visible text and drops scripts, styles, menus and comments", async () => {
    const page = `<html><head><style>.a{}</style><script>var x = "<p>no</p>";</script></head><body><nav>Menu</nav><header>Top</header><!-- hidden --><p>Visible &amp; clear.</p><form>Sign up</form><footer>Bottom</footer></body></html>`;
    fakeFetch([["page.example", htmlAnswer(page)]]);
    expect(await fetchReadableText("https://page.example/a")).toBe("Visible & clear.");
  });

  it("cuts the text to 2500 characters", async () => {
    fakeFetch([["page.example", htmlAnswer(`<p>${"word ".repeat(2000)}</p>`)]]);
    expect(await fetchReadableText("https://page.example/long")).toHaveLength(2500);
  });

  it("is empty for an error or something that isn't a web page", async () => {
    fakeFetch([["page.example", htmlAnswer("<p>gone</p>", 404)]]);
    expect(await fetchReadableText("https://page.example/gone")).toBe("");
    fakeFetch([["page.example", new Response("%PDF-1.7", { headers: { "content-type": "application/pdf" } })]]);
    expect(await fetchReadableText("https://page.example/file.pdf")).toBe("");
    fakeFetch([["page.example", new Response("no type")]]);
    expect(await fetchReadableText("https://page.example/untyped")).toBe("");
  });
});

describe("handleSearch", () => {
  const searchURL = (query: string, extra = "") => new URL(`https://worker.test/search?q=${encodeURIComponent(query)}${extra}`);
  const londonResult = { title: "London weather today", url: "https://weather.example/london", snippet: "Mild and cloudy in London" };
  const detroitResult = { title: "Detroit weather", url: "https://weather.example/detroit", snippet: "Cold" };

  it("answers 400 without a query", async () => {
    const response = await handleSearch(new URL("https://worker.test/search?q=%20%20"));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "missing q" });
    expect((await handleSearch(new URL("https://worker.test/search"))).status).toBe(400);
  });

  it("keeps the engine whose results cover the most of the query, and adds the top page's text", async () => {
    const calls = fakeFetch([
      [/bing\.com\/search\?q=/, htmlAnswer(bingPage([detroitResult]))],
      [/bing\.com\/search\?format=rss/, htmlAnswer(bingFeed([]))],
      ["html.duckduckgo.com", htmlAnswer(duckDuckGoPage([londonResult]))],
      ["weather.example/london", htmlAnswer(`<p>${pageText}</p>`)],
    ]);
    const answer = (await (await handleSearch(searchURL("weather in london today"))).json()) as any;
    expect(answer.query).toBe("weather in london today");
    expect(answer.source).toBe("duckduckgo");
    expect(answer.results).toEqual([londonResult]);
    expect(answer.topPage.url).toBe("https://weather.example/london");
    expect(answer.topPage.text).toContain("mild and cloudy");
    expect(answer.engines).toBeUndefined();
    expect(calls.some((call) => call.url.includes("wikipedia.org"))).toBe(false);
  });

  it("prefers Bing's page on a tie", async () => {
    fakeFetch([
      [/bing\.com\/search\?q=/, htmlAnswer(bingPage([londonResult]))],
      [/bing\.com\/search\?format=rss/, htmlAnswer(bingFeed([{ title: londonResult.title, link: "https://feed.example/london", description: londonResult.snippet }]))],
      ["html.duckduckgo.com", htmlAnswer(duckDuckGoPage([{ ...londonResult, url: "https://ddg.example/london" }]))],
      ["weather.example/london", htmlAnswer("<p>short</p>")],
    ]);
    const answer = (await (await handleSearch(searchURL("weather london"))).json()) as any;
    expect(answer.source).toBe("bing");
    // The page had too little text to be worth sending.
    expect(answer.topPage).toBeUndefined();
  });

  it("asks Wikipedia when no engine covers the query, and lists every engine with debug=1", async () => {
    const calls = fakeFetch([
      [/bing\.com\/search\?q=/, htmlAnswer(bingPage([detroitResult]))],
      [/bing\.com\/search\?format=rss/, htmlAnswer("", 500)],
      ["html.duckduckgo.com", () => { throw new Error("unreachable"); }],
      ["wikipedia.org/w/api.php", jsonAnswer({ query: { search: [{ title: "Climate of London", snippet: "London weather and rainfall" }] } })],
      ["en.wikipedia.org/wiki/", () => { throw new Error("page didn't load"); }],
    ]);
    const answer = (await (await handleSearch(searchURL("rainfall london", "&debug=1"))).json()) as any;
    expect(answer.source).toBe("wikipedia");
    expect(answer.results[0].title).toBe("Climate of London");
    expect(answer.topPage).toBeUndefined();
    expect(answer.engines.map((engine: { engine: string }) => engine.engine).sort()).toEqual(["bing", "bing-rss", "duckduckgo", "wikipedia"]);
    expect(answer.engines.find((engine: { engine: string }) => engine.engine === "duckduckgo")).toEqual({ engine: "duckduckgo", count: 0, coverage: 0, titles: [] });
    expect(calls.filter((call) => call.url.includes("wikipedia.org/w/api.php"))).toHaveLength(1);
  });

  it("answers with no results when every engine comes back empty", async () => {
    fakeFetch([
      ["bing.com/search", htmlAnswer("")],
      ["html.duckduckgo.com", htmlAnswer("")],
      ["wikipedia.org", jsonAnswer({})],
    ]);
    const answer = (await (await handleSearch(searchURL("zxqv"))).json()) as any;
    expect(answer).toEqual({ query: "zxqv", source: "", results: [] });
  });

  it("puts a Roblox game first for Roblox questions", async () => {
    fakeFetch([
      [/bing\.com\/search\?q=/, htmlAnswer(bingPage([{ title: "Grow a Garden roblox wiki", url: "https://wiki.example/garden", snippet: "garden guide" }]))],
      [/bing\.com\/search\?format=rss/, htmlAnswer("")],
      ["html.duckduckgo.com", htmlAnswer("")],
      ["apis.roblox.com", jsonAnswer({ searchResults: [{ contentGroupType: "Game", contents: [{ universeId: 7, rootPlaceId: 9, name: "Grow a Garden", description: "Plant seeds." }] }] })],
      ["roblox.com/games/9", htmlAnswer("<p>tiny</p>")],
      ["wiki.example/garden", htmlAnswer(`<p>${pageText}</p>`)],
    ]);
    const answer = (await (await handleSearch(searchURL("roblox grow a garden"))).json()) as any;
    expect(answer.source).toBe("roblox+bing");
    expect(answer.results[0].title).toBe("Grow a Garden (Roblox experience)");
    expect(answer.results).toHaveLength(2);
    // The first result's page was too short, so the second one is read.
    expect(answer.topPage.url).toBe("https://wiki.example/garden");
  });

  it("answers with only the Roblox game when the web engines find nothing, and survives Roblox failing", async () => {
    fakeFetch([
      ["bing.com/search", htmlAnswer("")],
      ["html.duckduckgo.com", htmlAnswer("")],
      ["wikipedia.org", jsonAnswer({})],
      ["apis.roblox.com", jsonAnswer({ searchResults: [{ contentGroupType: "Game", contents: [{ universeId: 7, rootPlaceId: 9, name: "Tiny Game", description: "Small." }] }] })],
      ["roblox.com/games/9", htmlAnswer("", 500)],
    ]);
    expect(((await (await handleSearch(searchURL("roblox tiny game"))).json()) as any).source).toBe("roblox");
    fakeFetch([
      ["bing.com/search", htmlAnswer("")],
      ["html.duckduckgo.com", htmlAnswer("")],
      ["wikipedia.org", jsonAnswer({})],
      ["apis.roblox.com", () => { throw new Error("roblox is down"); }],
    ]);
    expect(((await (await handleSearch(searchURL("roblox tiny game"))).json()) as any).results).toEqual([]);
  });

  it("cuts a very long query to 300 characters", async () => {
    fakeFetch([
      ["bing.com/search", htmlAnswer("")],
      ["html.duckduckgo.com", htmlAnswer("")],
      ["wikipedia.org", jsonAnswer({})],
    ]);
    const answer = (await (await handleSearch(searchURL("a".repeat(500)))).json()) as any;
    expect(answer.query).toHaveLength(300);
  });
});

describe("readTextUpTo", () => {
  const streamOf = (pieces: string[], onPull?: () => void) =>
    new ReadableStream<Uint8Array>({
      pull(controller) {
        onPull?.();
        const piece = pieces.shift();
        if (piece === undefined) controller.close();
        else controller.enqueue(new TextEncoder().encode(piece));
      },
    });

  it("returns the whole text of a short page", async () => {
    expect(await readTextUpTo(new Response(streamOf(["hello ", "there"])), 100)).toBe("hello there");
  });

  it("stops at the limit, in the middle of a piece", async () => {
    expect(await readTextUpTo(new Response(streamOf(["12345", "67890", "abcde"])), 7)).toBe("1234567");
  });

  it("does not keep reading a page that never ends", async () => {
    let piecesRead = 0;
    const endlessPage = new ReadableStream<Uint8Array>({
      pull(controller) {
        piecesRead += 1;
        controller.enqueue(new TextEncoder().encode("x".repeat(10)));
      },
    });
    expect(await readTextUpTo(new Response(endlessPage), 25)).toHaveLength(25);
    expect(piecesRead).toBeLessThan(10);
  });

  it("returns nothing for a response without a body", async () => {
    expect(await readTextUpTo(new Response(null), 100)).toBe("");
  });
});
