---
name: academic-paper-search
description: Use when the user wants scholarly papers found or summarized: "find papers on", "what does the research say", "get me citations", "summarize this arXiv paper", "make a reading list in APA".
---

# Academic Paper Search

## When to use

- Finding peer-reviewed papers, preprints or reviews on a topic.
- Summarizing a specific paper from a title, DOI or arXiv link.
- Building a reading list or bibliography in a chosen citation style (APA, MLA, Chicago, IEEE, BibTeX).
- Not for a broad report mixing papers, news and data: use `deep-research`.
- Not for checking one claim: use `fact-checking`.

## Steps

1. Turn the request into 2 or 3 search phrasings with the key terms and synonyms. Note any year range or field the user gave.
2. Search OpenAlex first (free, no key, covers most journals). Add `mailto` so requests go to the polite pool:
   `curl -s "https://api.openalex.org/works?search=sleep%20deprivation%20memory&filter=from_publication_date:2019-01-01,type:article&sort=cited_by_count:desc&per-page=25&mailto=helper@example.com" -o tmp/openalex.json`
3. For computing, physics and math, also search arXiv:
   `curl -s "http://export.arxiv.org/api/query?search_query=all:%22diffusion%20models%22&sortBy=submittedDate&max_results=20" -o tmp/arxiv.xml`
4. For citation counts and influential citations, Semantic Scholar works without a key at low rates:
   `curl -s "https://api.semanticscholar.org/graph/v1/paper/search?query=sleep+memory&fields=title,year,authors,venue,citationCount,externalIds,openAccessPdf,tldr&limit=20" -o tmp/s2.json`
5. Merge results into `tmp/papers.csv` (`title,year,authors,venue,doi,arxiv_id,citations,open_pdf,source`). Deduplicate by DOI, then by lowercase title.
6. Rank: relevance to the question first, then reviews and meta-analyses, then citation count adjusted for age, then recency. Keep 5 to 15.
7. For each kept paper, read the abstract (OpenAlex gives `abstract_inverted_index`; rebuild it in python). Read the full text only when an open PDF exists (`open_access.oa_url` or `openAccessPdf.url`).
8. Write `output/papers-<topic>.md`: a short overview of what the papers agree on, then one entry per paper with the citation, a 2 to 3 sentence plain summary (question, method, main result, sample size), and a link.
9. If the user asked for a style, format every citation in it. Also write `output/papers-<topic>.bib` when they want BibTeX or a reference manager.

## Tools on a Mac

- `curl` plus `python3 -m json.tool tmp/openalex.json | head -80` to inspect results.
- Rebuild an OpenAlex abstract:

```python
import json
works = json.load(open("tmp/openalex.json"))["results"]
for work in works:
    index = work.get("abstract_inverted_index") or {}
    positions = sorted((pos, word) for word, plist in index.items() for pos in plist)
    print(work["display_name"], work["publication_year"], work.get("doi"))
    print(" ".join(word for _, word in positions)[:600], "\n")
```

- arXiv XML: `python3 -c "import xml.etree.ElementTree as ET;..."` with namespace `{http://www.w3.org/2005/Atom}`.
- BibTeX from a DOI: `curl -sLH "Accept: application/x-bibtex" https://doi.org/10.1038/nature12373`.
- Formatted citation from a DOI: `curl -sLH "Accept: text/x-bibliography; style=apa" https://doi.org/10.1038/nature12373` (also `modern-language-association`, `chicago-author-date`, `ieee`).
- PDFs: `python3 -m pip install --user pypdf` to extract text.

## Quality checklist

- Every paper listed exists: its DOI or arXiv link resolves.
- Authors, year and venue come from the API data, never from memory.
- Summaries state the study type (trial, observational, review, preprint) and sample size where given.
- Preprints are labeled as not peer reviewed.
- Retracted papers are dropped or flagged (OpenAlex `is_retracted`).
- Citation style is consistent across the whole list.

## Reply to the user

One to three sentences: how many papers, the one-line takeaway, and the path, for example "I found 12 papers; most trials show a moderate memory drop after one night without sleep. The list with summaries and APA citations is in output/papers-sleep-memory.md."

## Pitfalls

- Making up citations. Never write a reference that did not come from an API result or a page you opened.
- Search by full title when the user names a paper; keyword search may return a lookalike.
- Citation counts favor old papers; do not rank a 2024 paper below a 2009 one on count alone.
- Semantic Scholar returns HTTP 429 when hit fast. Wait a few seconds between calls and keep to about one per second.
- arXiv asks for no more than one request every three seconds.
- Do not download paywalled PDFs from unofficial mirrors. Use open versions or the abstract.

Based on: ykdojo "paper-search"
