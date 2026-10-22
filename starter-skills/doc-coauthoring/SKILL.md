---
name: doc-coauthoring
description: Use when the user wants to write a long document together over several rounds: a proposal, spec, essay, report, plan or guide. "help me write", "let's draft", "work on my doc with me".
---

# Doc Co-authoring

## When to use

- Long or important writing where the user's knowledge matters: proposals, design docs, grant applications, policies, reports, essays, guides.
- Work that will take several turns: outline, then sections, then revisions.
- Not for a quick message: use `email-drafting` or `internal-comms`.
- Not for file format work: once the text is done, use `word-documents`, `pdf-tools` or `slide-decks` to produce the file.

## Steps

Work in rounds. Each round ends with a short reply and one clear question, because the user hears your reply in a few sentences, not a page.

1. Frame (round 1). Find out the doc type, who reads it, what the reader should do or decide after reading, length, deadline, and any template. Ask at most three questions at once. Write the answers to `output/<slug>/brief.md`.
2. Gather context (round 1 to 2). Ask the user to point you at files, links or notes, or to just talk through what they know. Read everything they give. Keep a running list of facts, numbers and claims with their sources in `output/<slug>/notes.md`. List what is still missing.
3. Outline (round 2). Write `output/<slug>/outline.md`: section headings, and under each one sentence saying what that section must establish. Ask the user to confirm or reorder before drafting.
4. Draft one section at a time (rounds 3+). Start with the section the user knows best or the hardest one, not necessarily the first. Write it into `output/<slug>/draft.md`. For each section, offer 2 or 3 specific choices where you are unsure ("lead with the cost or the risk?") rather than asking "any thoughts?".
5. Revise from feedback. Change only what the user asked for; keep their own phrases. Keep a short `output/<slug>/changes.md` log so nothing silently disappears.
6. Reader test (last round). Reread the full draft as the target reader with no background. Check: can they say the main point after the first paragraph? Is every term defined? Is the ask clear? Is anything repeated? Write findings to `output/<slug>/reader-test.md` and fix the real ones.
7. Finish: one clean file `output/<slug>/<slug>.md`, and the requested format via the matching skill.

## Tools on a Mac

- Files are plain Markdown; read with `cat`, search with `rg` (or `grep -rn`).
- Word count: `wc -w output/<slug>/draft.md`.
- Read the user's sources: `textutil -convert txt -stdout file.docx`, `pdftotext -layout file.pdf -` (`brew install poppler`), `curl -sL <url>` or the web fetch tool for pages.
- Compare versions: `diff -u old.md new.md` or `git diff --no-index old.md new.md`.
- Turn the final text into a file: `pandoc output/<slug>/<slug>.md -o output/<slug>/<slug>.docx` (`brew install pandoc`).
- Read a section aloud to check flow if the user asks: `say -f tmp/section.txt`.

## Quality checklist

- The first paragraph states the point and what the reader should do.
- Every section does what its outline sentence promised.
- Every number and claim traces to the user's material or a cited source; nothing invented.
- Headings are parallel and scannable; paragraphs under about 120 words.
- Terms and acronyms are defined on first use.
- The user's voice is kept: their phrasing and their opinions, not yours.
- Length is within the target.

## Reply to the user

One to three sentences: what you did this round, where it is, and the one question that moves things forward. For example: "Drafted the Budget section in output/grant-2027/draft.md. Should I put the cost table first or the justification first?" Do not paste the draft into the reply.

## Pitfalls

- Drafting the whole document before the outline is agreed wastes the user's time and buries their ideas.
- Filling gaps with plausible-sounding facts. Mark them `[TODO: need the real figure]` instead.
- Asking open questions ("what do you think?") instead of concrete choices.
- Rewriting sections the user already approved while fixing another.
- Long replies: the user hears them. Keep the substance in the files.
- Losing context between rounds: always reread `brief.md`, `notes.md` and `outline.md` at the start of a turn.

Based on: anthropics/skills "doc-coauthoring"
