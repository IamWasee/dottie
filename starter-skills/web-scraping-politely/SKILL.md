---
name: web-scraping-politely
description: Use when the user wants data collected from websites into a file: "scrape this site", "pull all the listings from", "get every product and price into a spreadsheet", "download the table on this page".
---

# Web Scraping Politely

## When to use

- Collecting structured data (lists, tables, prices, listings, article titles) from public web pages into CSV or JSON.
- Pages that need JavaScript to show their content (use Playwright, see Steps).
- Not for reading one page to answer a question: the helper's web fetch is enough.
- Not for analyzing the data afterwards: hand the CSV to `csv-data-analysis`.
- Not for anything behind a login, a paywall or a CAPTCHA. Stop and tell the user.

## Steps

1. Look for an official way first: a public API, an RSS feed, a download link, or a sitemap (`/sitemap.xml`). Use it if it exists.
2. Read the rules. Fetch `https://site.example/robots.txt` and check the paths you need against it with `urllib.robotparser`. Skim the site's terms for a ban on automated access. If either forbids it, stop and tell the user.
3. Fetch one sample page with `curl` and save it to `tmp/sample.html`. If the data is in the HTML, use requests + BeautifulSoup. If the HTML is nearly empty and the data appears only in the browser, look in the page for a JSON API call (often under `/api/` or in a `<script type="application/json">`) before reaching for Playwright.
4. Write the scraper in `tmp/scrape.py`:
   - Identify yourself: a User-Agent like `DottieHelper/1.0 (personal research)`.
   - One request at a time, at least 1 to 2 seconds apart (more if robots.txt sets `Crawl-delay`).
   - Timeouts (`timeout=20`), up to 3 retries with growing waits on 429 and 5xx, stop on 403.
   - Cache each fetched page in `tmp/cache/` so reruns do not hit the site again.
5. Parse with CSS selectors that describe meaning (`article h2 a`, `table#prices tr`), not long brittle paths. Strip whitespace, convert prices and dates to plain values, keep the source URL for each row.
6. Run on 2 or 3 pages first and check the output by eye. Then run the full job, with a hard cap on pages (for example 500) unless the user set one.
7. Save results to `output/<name>.csv` (UTF-8, header row) and, for nested data, `output/<name>.json`. Add a `scraped_at` column with the date.
8. Report counts: pages fetched, rows saved, pages that failed.

## Tools on a Mac

- `curl -sL -A "DottieHelper/1.0" https://site.example/robots.txt`.
- `python3 -m pip install --user requests beautifulsoup4 lxml`.

```python
import time, requests, urllib.robotparser
from bs4 import BeautifulSoup
robots = urllib.robotparser.RobotFileParser("https://site.example/robots.txt"); robots.read()
session = requests.Session(); session.headers["User-Agent"] = "DottieHelper/1.0 (personal research)"
url = "https://site.example/catalog?page=1"
assert robots.can_fetch(session.headers["User-Agent"], url)
soup = BeautifulSoup(session.get(url, timeout=20).text, "lxml")
rows = [{"title": card.select_one("h2").get_text(strip=True), "url": url} for card in soup.select("article")]
time.sleep(2)
```

- JavaScript pages: `python3 -m pip install --user playwright && python3 -m playwright install chromium`, then `page.goto(url, wait_until="networkidle")` and `page.content()` into BeautifulSoup.
- HTML tables: `pandas.read_html("tmp/sample.html")` returns every `<table>` as a DataFrame.
- `python3 -m json.tool output/items.json | head` to check JSON.

## Quality checklist

- robots.txt was checked and the scraper obeys it, including Crawl-delay.
- Requests were spaced out; no parallel hammering.
- Row count is plausible against what the site shows (for example "1,240 results").
- No empty or shifted columns; spot-check 5 rows against the live pages.
- Each row has its source URL and the scrape date.
- No personal data about private individuals was collected beyond what the user's task needs.

## Reply to the user

One to three sentences: what you collected, how many rows, anything skipped, and the path, for example "I saved 1,236 listings with price and location to output/listings.csv; 4 pages failed and are noted in the file's log."

## Pitfalls

- Ignoring robots.txt or terms "just this once". If it is disallowed, say so and suggest the official API or a manual export.
- Logging in, solving CAPTCHAs, rotating IPs or faking browsers to get around blocks. Do not.
- Pagination that loops forever; track seen URLs and stop on repeats.
- Selectors that silently match nothing after a layout change: fail loudly when a page yields zero rows.
- Prices in the HTML may differ by region or need a cookie; note which version you got.
- Never store the user's passwords or cookies in scripts.

Based on: written for Dottie
