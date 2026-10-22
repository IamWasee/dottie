---
name: routine-reports
description: Use when running a repeating check or routine ("check every hour", "tell me when this changes", "daily summary of X"), so each run compares with the last and reports only what's new.
---

# Routine Reports

## When to use

- Any run of a routine: watching a page, a price, a feed, an inbox count, a folder, a release list, a search result.
- Setting up a new repeating check, so the first run leaves good notes for the next.
- Not for one-off research: just answer it.

## Steps

1. Start every run by reading your notes: `state.json` and `last-report.md` in the folder (create both on the first run). They are your memory between runs; the conversation may have been reset.
2. Fetch the current data the same way every time (same URL, same query, same sort). Save the raw copy to `tmp/run-latest.<ext>`.
3. Reduce it to comparable items, each with a stable id: a URL, a SKU, a title plus date, a file path. Store a short fingerprint per item (price, status, a hash of the text) rather than whole pages.
4. Compare with `state.json`: new items, removed items, changed fields. Ignore noise that changes every load (timestamps, view counts, ad blocks, "updated 3 minutes ago").
5. Decide:
   - Nothing meaningful changed: reply exactly `NOTHING NEW` and nothing else. Still update `last_checked` in `state.json`.
   - Something changed: write a short report of only the changes, newest first, each with its link.
6. Write the new state atomically: write `state.tmp.json`, then `mv state.tmp.json state.json`, so a crash never leaves half a file.
7. Save the report to `last-report.md` and append a one-line entry to `output/routine-log.md` (date, what changed).
8. If the source failed (timeout, 404, login wall, captcha), don't report a change. Record `consecutive_failures` and say plainly that the check failed and why. Never treat an error page as "everything was removed".

## Tools on a Mac

- `curl -sL --max-time 30 -A "Mozilla/5.0" URL -o tmp/run-latest.html`
- `python3` for parsing and diffing; `json`, `hashlib` and `html.parser` are built in.
- `shasum -a 256 file` for a quick fingerprint.
- `diff -u old.txt new.txt` for text lists.
- `textutil -convert txt -stdout page.html` to strip HTML to text.
- `brew install jq` for poking at JSON APIs: `jq '.items[] | {id, price}'`.
- A minimal state file:

```json
{
  "source": "https://example.com/deals",
  "last_checked": "2026-10-22T09:00:00Z",
  "last_changed": "2026-10-21T15:00:00Z",
  "consecutive_failures": 0,
  "items": {
    "sku-123": {"title": "Desk lamp", "price": 39.0, "first_seen": "2026-10-20"}
  }
}
```

## Quality checklist

- Read the previous state before fetching.
- Every reported item is actually new or changed since the last run, not since the first.
- No change means the reply is exactly `NOTHING NEW`, with no greeting or punctuation added.
- Thresholds the user set are respected (for example "only if the price drops below 50").
- `state.json` was saved even when nothing changed, and parses: `python3 -m json.tool state.json > /dev/null`.
- Links included for each change.

## Reply to the user

When something changed: one to three short sentences that lead with the change, for example "The lamp dropped from $39 to $29, and two new desks were listed. Details in output/routine-log.md." When nothing changed: exactly `NOTHING NEW`.

## Pitfalls

- Reporting the same item twice because its id was unstable (tracking parameters in URLs). Strip `utm_*` and similar before using a URL as an id.
- Pages that change layout make everything look "new". If more than half the items changed at once, suspect the parser, check, and say so instead of flooding the user.
- Saying "nothing new" on the first run. The first run reports the starting picture briefly and sets the baseline.
- Taking actions on a change (buying, replying, posting) without the user's yes. A routine reports; it doesn't act unless the user set that up and confirmed it.
- Dates in different time zones; store UTC ISO 8601.
- Letting `output/routine-log.md` grow forever; keep the last 200 lines.

Based on: written for Dottie
