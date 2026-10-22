# How starter skills are written

These are Dottie's starter skills: they ship inside the app and are copied into the user's skills library (`~/Library/Application Support/Dottie/Skills/<name>/SKILL.md`). Dottie's helpers ("Dots") read them when a task calls for it. A helper is Gemini CLI or Claude Code, running headless in its own folder on the user's Mac (`output/` for results, `tmp/` for scratch), with a shell, file tools and web search/fetch. It cannot click on screen unless the computer-use skill is on. It talks to the user only through its final reply, which Dottie shows in the notch and may read aloud, so replies are short.

## File format

`starter-skills/<name>/SKILL.md`, `<name>` lowercase words and hyphens, exactly:

```
---
name: <name>
description: Use when <specific trigger: the words a user would say and the kind of task>. <optional second short clause>
---

# <Title>

...body...
```

- `description`: one or two sentences, under 220 characters, starting "Use when". It is the only part the helper sees before deciding to load the skill, so name the concrete triggers.
- Body: 60 to 130 lines of real, specific instructions a helper can follow. Sections, in this order, using `##` headings:
  - **When to use** (and when not to, pointing at a sibling skill if one fits better)
  - **Steps** (numbered, concrete: which commands, file formats, checks)
  - **Tools on a Mac** (exact commands: built-ins first, like `textutil`, `sips`, `qlmanage`, `mdls`, `osascript`, `shortcuts`, `pbcopy`, `screencapture`, `afconvert`, `say`, `open`, `curl`, `python3`; then Homebrew or pip packages, installed only when needed with `brew install x` or `python3 -m pip install --user x`, and only well-known ones)
  - **Quality checklist** (bullets the helper checks before finishing)
  - **Reply to the user** (what the final reply says: one to three plain sentences, the file path in `output/`, no walls of text)
  - **Pitfalls** (real mistakes to avoid)
- End with one line: `Based on: <the popular skill or project it is modeled on, e.g. anthropics/skills "docx", obra/superpowers "systematic-debugging">` or `Based on: written for Dottie`.

## Rules

- Write original text. Do not copy wording from the source skills; adapt the idea to Dottie's setting (a Mac, a helper folder, short spoken replies).
- Be concrete: real commands with real flags, real file formats, real limits. No filler, no marketing.
- Never tell the helper to ask for or store passwords, API keys or payment details. Anything that sends, posts, buys, deletes, or publishes outside the Mac waits for the user's yes.
- Plain ASCII punctuation; no em dashes.
- Don't mention Dottie's internals beyond what's above.
