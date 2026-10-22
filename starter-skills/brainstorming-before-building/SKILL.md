---
name: brainstorming-before-building
description: Use when the user has a vague idea to build ("make me an app that...", "I want a tool for...", "help me design") and no agreed design yet. Turn it into a short design.md before any code.
---

# Brainstorming Before Building

## When to use

- The user asks for something to be built but the goal, users, inputs or limits are fuzzy.
- The request could be read two or more ways and the readings lead to different code.
- A new project, feature or script that will take more than about 30 minutes of work.

Do not use when:

- The task is a small, clear change ("rename this function", "fix this typo"). Just do it, following careful-coding-rules.
- A design already exists and the user wants the work split into steps. Use writing-plans.
- Something is broken. Use systematic-debugging.

## Steps

1. Look before asking. Read what is already in the folder (`ls -la`, any README, package.json, pyproject.toml, Package.swift) so you do not ask questions the files already answer.
2. Write down, for yourself, what you think the user wants in one sentence. Note the gaps: who uses it, what goes in, what comes out, where it runs, what "done" looks like.
3. Ask one question at a time. Your reply is shown in a small notch card and may be read aloud, so each question is one short sentence. Prefer multiple choice: "Should it run as (a) a menu bar app, (b) a command line script, or (c) a web page?"
4. Ask the most important unknown first: purpose and success criteria, then constraints (platform, language, offline, budget), then nice-to-haves. Stop asking when the remaining gaps would not change the design. Three to five questions is usually enough.
5. If the user says "you decide", pick the simplest option that meets the stated goal and say which one you picked.
6. Propose 2 or 3 approaches. For each give: one line on how it works, the main trade-off, and rough effort (small, medium, large). Lead with the one you recommend and say why in one sentence.
7. Once the user picks (or agrees with your pick), write `output/design.md` with these sections:
   - Goal: one or two sentences.
   - Users and use: who runs it and how.
   - Scope: what is in, and an explicit "Not in this version" list.
   - Approach: the chosen design, main parts and how data flows between them.
   - Interfaces: commands, file formats, screens or API shapes, with one concrete example each.
   - Risks and open questions.
   - Success criteria: checks that prove it works (a command and its expected output, a file that must exist).
8. Keep design.md under about 100 lines. If it grows past that, the scope is too big; split off a later version.
9. Ask the user to confirm the design before writing any code. Do not start building in the same turn unless they already said "go ahead and build it".
10. When confirmed, hand off to writing-plans to turn design.md into plan.md.

## Tools on a Mac

- Look at the folder: `ls -la`, `find . -maxdepth 2 -type f | head -50`, `cat README.md`.
- Check what is installed before proposing it: `which python3 node swift git`, `python3 --version`, `node --version`, `swift --version`.
- Check macOS version when it matters for an approach: `sw_vers -productVersion`.
- Quick research on an unfamiliar library or API: use web search, then read the official docs page with web fetch or `curl -sL <url>`.
- Preview the design file: `open output/design.md` (opens in the default text editor) or `qlmanage -p output/design.md`.
- Copy a short summary for the user: `pbcopy < output/design.md`.

## Quality checklist

- Every question you asked was one question, short enough to hear in one breath.
- At least two real approaches were offered, with an honest trade-off for each.
- design.md has a "Not in this version" list and measurable success criteria.
- No code, scaffolding or installs happened before the user agreed.
- Assumptions you made on the user's behalf are written in design.md under Risks and open questions.

## Reply to the user

While gathering requirements: just the one question, with options if possible.
When done: "I wrote the design to output/design.md. I recommend <approach> because <reason>. Want me to plan the build?"

## Pitfalls

- Asking five questions in one reply. The user hears a wall of text and answers only the last one.
- Asking things you could have found by reading the folder or the docs.
- Offering fake alternatives where two options are the same idea with different names.
- Gold-plating the design with accounts, settings screens and sync when the user asked for a script.
- Skipping the design because the idea "seems obvious", then rebuilding after the first demo.
- Treating "you decide" as permission to pick the most interesting option instead of the simplest.

Based on: obra/superpowers "brainstorming"
