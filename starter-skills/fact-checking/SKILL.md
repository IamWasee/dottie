---
name: fact-checking
description: Use when the user wants a claim, quote, statistic or article checked: "is this true", "fact-check this", "did X really say", "is this number right", "check this post before I share it".
---

# Fact Checking

## When to use

- One or a handful of specific claims: a statistic, a quote, a news story, a viral post, a line in the user's own draft.
- Checking whether information is still current (prices, laws, records, who holds a role).
- Not for open questions with no single claim to test: use `deep-research`.
- Not for finding scholarly literature in general: use `academic-paper-search`, then come back to rate claims against it.

## Steps

1. Pull out each checkable claim and write it in `tmp/claims.md` as a plain sentence. Split compound claims ("X rose 40% and is the highest ever" is two claims). Skip opinions; say they are opinions.
2. For each claim, decide what would settle it: an official dataset, the original study, a transcript or video, a law text, a company filing.
3. Search for that primary source directly. Use fact-checking sites (Snopes, PolitiFact, Full Fact, AFP Fact Check, Reuters Fact Check) as leads, then confirm against the original.
4. Open and read the source. Record the exact quote or figure, the URL, and the date it was published or last updated.
5. Check the date. If the claim was true once but has changed, mark it outdated and give the current value with its date.
6. Check context: is the number per year or total, in which country, which units, adjusted or nominal? Was the quote cut in a way that changes its meaning?
7. Rate each claim:
   - **True**: primary source confirms it as stated.
   - **Mostly true**: right in substance, a detail is off (rounding, date, wording).
   - **Misleading**: the facts are real but the framing gives a wrong impression.
   - **False**: primary sources contradict it.
   - **Outdated**: was true, no longer is.
   - **Unclear**: no reliable source either way, or good sources disagree.
8. Write `output/fact-check.md`: a table `Claim | Rating | What the source says | Source (link, date)`, then one short paragraph per claim that is not plainly true.

## Tools on a Mac

- The helper's web search and fetch tools.
- Older versions of a page (to see what it said when the claim was made): `curl -s "https://archive.org/wayback/available?url=example.com/page&timestamp=20230101"` returns the closest snapshot URL.
- `curl -sI https://example.com/page | grep -i last-modified` for a hint of when a page changed.
- Images: reverse search is not available offline; check `mdls -name kMDItemContentCreationDate -name kMDItemWhereFroms image.jpg` and `sips -g all image.jpg` for embedded dates and origin.
- PDFs and reports: `python3 -m pip install --user pypdf` to read the original document text.

## Quality checklist

- Every rating has at least one link to a primary or clearly authoritative source.
- The source actually contains the figure or quote; it was opened, not inferred from a snippet.
- Dates are given for each source and for each "current" value.
- "Unclear" is used honestly instead of forcing a verdict.
- The wording of each claim matches what the user gave; the check is not of a weaker or stronger version.
- Opinion, prediction and satire are named as such, not rated true or false.

## Reply to the user

One to three sentences with the verdicts in plain words and the path, for example "The 40% figure is true for 2022 but outdated; the 2024 number is 31%. The quote is real but cut short. Details and links are in output/fact-check.md." For a single claim, the verdict and one link in the reply is enough.

## Pitfalls

- Trusting a fact-check site's verdict without reading its sources.
- Rating a claim false because one source disagrees, when better sources support it.
- Missing that a statistic is real but for a different country, year or group.
- Quotes attributed to famous people are often invented; look for the original speech, book or recording.
- Wikipedia is a starting point, not the evidence. Follow its footnotes.
- Do not post corrections or reply to anyone on the user's behalf; the report is the job.

Based on: written for Dottie
