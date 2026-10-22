---
name: pricing-and-competitor-research
description: Use when the user wants competitors compared or a price set: "who are my competitors", "compare these apps", "how should I price this", "what do others charge", "make a competitor table".
---

# Pricing and Competitor Research

## When to use

- Mapping the competitors of a product, app, service or small business.
- Comparing features, prices and positioning in a table.
- Choosing a pricing model and price points with reasons.
- Not for a general market or industry report: use `deep-research`.
- Not for launch plans and post copy: use `product-launch-marketing`.

## Steps

1. Write down the user's product in `tmp/brief.md`: what it does, for whom, platform, current or planned price, and region and currency. Fill gaps with stated assumptions.
2. Find competitors in three rings:
   - Direct: same job, same audience (search "<job> app", "<competitor> alternatives", app store categories, Product Hunt, G2 or Capterra categories).
   - Indirect: different product, same job (spreadsheets, a general tool, an agency).
   - Free or built-in options (what the OS or a big platform already gives away).
   Keep 5 to 10, mostly direct.
3. For each, open the official pricing page and record the facts in `tmp/competitors.csv`: `name,url,pricing_page,checked_on,model,free_tier,plans_and_prices,billing,key_features,limits,target_customer,positioning_line,notes`. Note monthly versus annual price, currency and whether tax is included.
4. Positioning: copy the headline from each homepage in your own short paraphrase (who it is for, main promise). Note review themes from app stores or review sites: what users praise and complain about.
5. Build the comparison in `output/competitors.md`:
   - A table: Name | For whom | Model | Free tier | Entry price | Top price | Standout features | Weak spots.
   - A feature matrix (yes/no/partial) for the 6 to 10 features that matter to the user's buyers.
   - Gaps: what nobody does well, which audience is underserved.
6. Pricing models to weigh, with their fit:
   - Freemium: wide funnel, needs a clear paid line (limits on usage, seats, or pro features).
   - Free trial then paid: works when value shows within 7 to 14 days.
   - Tiers (Good/Better/Best): anchor with a high tier; most buyers pick the middle.
   - Usage-based: fits costs that scale with use (API calls, storage, minutes).
   - One-time purchase: common for Mac utilities; plan for paid major upgrades.
   - Per seat: for team tools.
7. Recommend: one model and 2 or 3 concrete price points, each with its reasoning (competitor range, cost to serve, perceived value, audience budget). Give one alternative and what would make it the better choice. Suggest a simple test (for example, two prices for new visitors for two weeks).
8. Put the recommendation at the top of `output/competitors.md`, and save the raw data as `output/competitors.csv`.

## Tools on a Mac

- The helper's web search and fetch tools for pricing pages and reviews.
- `curl -sL -A "Mozilla/5.0" https://competitor.example/pricing -o tmp/pricing-competitor.html` then `textutil -convert txt -stdout tmp/pricing-competitor.html | grep -iE '\$|per month|/mo|year'`.
- App Store data without scraping: `curl -s "https://itunes.apple.com/search?term=habit+tracker&entity=software&country=us&limit=25"` (JSON with price, rating, review count, seller).
- Single app lookup: `curl -s "https://itunes.apple.com/lookup?id=<app id>&country=us"`.
- Pricing pages that need JavaScript: Playwright as in `web-scraping-politely`.
- `python3 -m pip install --user pandas tabulate` and `df.to_markdown()` to turn the CSV into a table.

## Quality checklist

- Every price has its source URL, currency, billing period and the date it was checked.
- Competitors are real and current (site live, product still sold).
- The table compares like with like (monthly vs monthly, per user vs per user).
- The recommendation follows from the data and says what assumption it rests on.
- Opinions about competitors are framed as review themes, with where they came from.

## Reply to the user

Two or three sentences: the key insight, the recommended price, and the path, for example "Most rivals charge $4 to $8 a month with a free tier; I'd suggest freemium with Pro at $5.99 a month or $39 a year. The table and reasoning are in output/competitors.md."

## Pitfalls

- Using prices from articles or memory; pricing pages change often. Always check the live page.
- Missing regional pricing; App Store prices differ by country.
- Counting "contact sales" as free or missing; record it as custom pricing.
- Copying a competitor's price without asking whether the user's costs and audience match.
- Signing up for trials, entering payment details or contacting competitors. Do not.

Based on: written for Dottie
