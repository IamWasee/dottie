---
name: deep-research
description: Use when the user wants a topic researched in depth across many sources: "research this", "dig into", "write me a report on", "what does the evidence say about". Produces a cited report.md.
---

# Deep Research

## When to use

- Open questions that need many sources weighed against each other: markets, history, technologies, policies, health or science topics.
- The user wants a written report with citations, not a one-line answer.
- Not for a single claim to verify: use `fact-checking`.
- Not for finding scholarly papers only: use `academic-paper-search` (and come back here if the papers feed a wider report).
- Not for a recurring update on a topic: use `news-briefing`.
- Not for a competitor or pricing table: use `pricing-and-competitor-research`.

## Steps

1. Restate the question in one sentence in `tmp/plan.md`. Note the scope the user gave (time range, region, audience) and assume sensible defaults when they gave none; write the assumptions down.
2. Break it into 4 to 8 sub-questions. Each must be answerable from sources, for example "What did the 2024 FDA guidance change?" rather than "Is it good?".
3. Search widely for each sub-question. Run at least two differently worded searches per sub-question, and include one search aimed at critics or opposing views.
4. Prefer primary sources: official statistics, laws and filings, original studies, company documentation, direct statements. Use news and blogs to find those, then cite the primary source.
5. Read the actual page, not the search snippet. Fetch it, save the readable text to `tmp/sources/NN-short-name.txt`, and note the publish date and author.
6. Track every claim in `tmp/claims.csv` with columns `claim,source_url,source_type,date,quote_or_number,sub_question`. One row per claim. Numbers get the exact figure and unit.
7. Look for disagreement. When sources conflict, record both sides with links and say which is stronger and why (newer data, larger sample, primary versus secondary, conflict of interest).
8. Stop searching when new sources only repeat what you have, or after about 25 sources read, whichever comes first. Note any sub-question you could not answer.
9. Write `output/report.md` (use a topic slug, for example `output/report-heat-pumps.md`):
   - Title and date.
   - Summary: 4 to 6 bullets with the main findings.
   - One section per sub-question, each claim followed by a numbered citation like `[3]`.
   - "Where sources disagree".
   - "Limits of this report": gaps, paywalled sources, things that may change soon.
   - "Sources": numbered list with title, publisher, date and URL.
10. Reread the report against `tmp/claims.csv`; every number and strong claim must trace to a row.

## Tools on a Mac

- Web search and web fetch tools of the helper are the main instruments.
- `curl -sL -A "Mozilla/5.0" "https://example.org/page" -o tmp/sources/01-page.html` when fetch fails.
- `textutil -convert txt -stdout tmp/sources/01-page.html` to strip HTML to text.
- PDFs: `python3 -m pip install --user pypdf`, then `python3 -c "import pypdf,sys;print('\n'.join(p.extract_text() or '' for p in pypdf.PdfReader(sys.argv[1]).pages))" tmp/sources/02-report.pdf`.
- `mdls -name kMDItemContentCreationDate file.pdf` sometimes recovers a document date.
- Optional: `brew install pandoc` and `pandoc output/report.md -o output/report.docx` when the user wants Word.
- `open output/report.md` only if the user asked to see it.

## Quality checklist

- Every factual sentence that is not common knowledge has a citation.
- Every citation number resolves to a real URL in the Sources list, and that URL was actually opened.
- Dates are given for statistics and for anything that changes over time.
- At least one opposing or skeptical source was looked for, and the report says what it found.
- Assumptions about scope are stated near the top.
- No source is cited for something it does not say; quotes are exact.
- The summary can be understood without reading the rest.

## Reply to the user

Two or three sentences: the main finding in plain words, how many sources it rests on, and the path, for example "Most studies find heat pumps cut heating bills by a third in mild climates, less in very cold ones; the full report with 18 sources is in output/report-heat-pumps.md."

## Pitfalls

- Citing a search result page or an aggregator instead of the original source.
- Treating a press release as independent evidence about the company that issued it.
- Old numbers presented as current. Always check the date of the figure, not the date of the article.
- Circular sourcing: five articles that all copy one original count as one source.
- Letting the first source frame the whole report. Plan sub-questions before reading deeply.
- Paywalls: do not try to get around them. Use the abstract or a free version and say so.
- Overlong reports. A focused 1,500 to 3,000 word report is better than an exhaustive one nobody reads.

Based on: popular deep-research skills
