---
name: news-briefing
description: Use when the user wants a short news update on topics they follow: "brief me on", "what's new with", "daily AI news", "weekly roundup of", "catch me up on". Also for repeating briefings.
---

# News Briefing

## When to use

- A daily or weekly digest on a few topics, companies, people or places the user follows.
- "Catch me up" requests after the user was away.
- Repeating briefings that should stay quiet when nothing happened.
- Not for a deep report on one question: use `deep-research`.
- Not for checking whether a specific story is true: use `fact-checking`.

## Steps

1. Keep the topic list in `briefing-topics.md` in the helper folder: one topic per line with optional notes ("Apple: only product and legal news", "local: Austin, TX"). Create it from the user's request the first time; update it when they add or drop topics.
2. Read `briefing-log.md` (create it if missing). It holds the date of the last briefing and the headlines and URLs already reported, so you do not repeat them.
3. Set the window: since the last briefing, or the last 24 hours for daily and 7 days for weekly when there is no log.
4. For each topic, run 2 or 3 searches with the date in mind ("<topic> news this week", the key names, official sources). Prefer:
   - Original reporting from established outlets (Reuters, AP, BBC, Bloomberg, FT, the major national papers, respected trade press).
   - Primary sources: official announcements, filings, release notes, government sites.
   - Avoid content farms, AI-rewritten aggregators and anonymous social posts as the only source.
5. Open each candidate story and confirm its publish date falls inside the window. Drop rewrites of old news.
6. Merge duplicates: one item per event, linked to the best original source, with a second source for anything surprising.
7. Rank by how much it matters to the user's stated interest, not by how loud it is. Keep 3 to 8 items in total.
8. If nothing new and meaningful happened on any topic, do not pad. Write nothing and reply with exactly `NOTHING NEW`.
9. Otherwise write `output/briefing-YYYY-MM-DD.md`:
   - Title with the date and window ("Oct 15 to Oct 22").
   - Per topic, items as: **Headline in plain words** (date) one or two sentences on what happened and why it matters. [Source](url)
   - "Quiet" line listing topics with no news.
10. Append the reported headlines, URLs and today's date to `briefing-log.md`. Trim entries older than 60 days.

## Tools on a Mac

- The helper's web search and fetch tools.
- RSS feeds are reliable and cheap: `curl -sL https://feeds.example.com/rss.xml -o tmp/feed.xml`, then parse with `python3 -m pip install --user feedparser` and filter by `entry.published_parsed`.
- Google News RSS for a query: `curl -sL "https://news.google.com/rss/search?q=%22Rivian%22+when:7d&hl=en-US&gl=US&ceid=US:en"` (use it to find stories, then cite the original outlet).
- `date -v-7d +%Y-%m-%d` gives the date a week ago on macOS.
- `say -f output/briefing-2026-10-22.md` only if the user asks to hear the whole file.

## Quality checklist

- Every item has a date and a working link to the original source.
- Nothing is older than the window, and nothing repeats the log.
- Each item says why it matters in one clause, without hype words.
- Rumors and single-source claims are labeled as such.
- The briefing reads in under two minutes.
- `briefing-log.md` was updated.

## Reply to the user

Short enough to be read aloud: the one or two biggest items in a sentence each, then the path, for example "Big one: the EU fined Apple 500 million euros over App Store rules. Four more items are in output/briefing-2026-10-22.md." When nothing changed, the whole reply is `NOTHING NEW`.

## Pitfalls

- Reporting an article's crawl date instead of its publish date.
- Padding a quiet day with background pieces, opinion columns or old news.
- Citing an aggregator when the original outlet is available.
- Paywalled stories: summarize only what is visible and say it is paywalled; do not bypass.
- Political and contested topics: report what happened and who said what, without taking sides.
- Do not share, post or email the briefing anywhere; saving it is the job.

Based on: written for Dottie
