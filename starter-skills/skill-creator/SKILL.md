---
name: skill-creator
description: Use when the user says "make a skill", "save this as a skill", "remember how to do this" or wants a repeatable how-to added to the skills library, or an existing skill fixed or sharpened.
---

# Skill Creator

## When to use

- The user asks to turn a task, a workflow or a set of house rules into a skill.
- You just finished a task that took real trial and error and the user is likely to ask again (same file type, same site, same report). Offer to save it; write it only on a yes.
- An existing skill fired at the wrong time, missed a step or gave stale commands: edit it.
- Not worth a skill: a one-off task, a single command, a fact about the user (that belongs in your notes), or something any helper already does well without help.

## Steps

1. Name the job in one line: what input, what output, what makes it done. If you cannot, it is not ready to be a skill.
2. Pick a name: lowercase words joined by hyphens, two or three words, saying the job (`invoice-pdfs`, `weekly-sales-report`). Check the library first so you do not duplicate one: `ls "$HOME/Library/Application Support/Dottie/Skills"` and `grep -l "^name:" */SKILL.md`.
3. Write the description first, because it is the only part a helper sees before loading. Start with "Use when", then the phrases a user would actually say and the kind of file or site involved. One or two sentences, under 220 characters. Bad: "Helps with reports." Good: "Use when the user wants the Monday sales report from Stripe exports: 'do the weekly numbers', 'sales recap'."
4. Create the folder and file: `<library>/<name>/SKILL.md`, starting with front matter:

```
---
name: weekly-sales-report
description: Use when ...
---
```

5. Write the body with `##` sections in this order: When to use (and when a sibling skill fits better), Steps (numbered, concrete), Tools on a Mac (exact commands and flags), Quality checklist, Reply to the user, Pitfalls. Keep it between about 60 and 130 lines.
6. Put the hard-won details in: the exact command that worked, the flag that broke it, the file path, the column name, the limit you hit. Leave out what a capable helper knows already.
7. Supporting files (a script, a template) go in the same folder; reference them by relative path, for example `scripts/clean.py`, and keep them small.
8. Test it on a real task: in `tmp/`, follow only what the skill says, from a fresh start, on a real input the user gave you. Note every place you had to guess.
9. Fix the guesses, then test once more. If the description would not have triggered for the user's real phrasing, add that phrasing.

## Tools on a Mac

- `ls`, `cat`, `grep -n` to read the library and check for overlaps.
- `mkdir -p "<library>/<name>"` and your file tools to write `SKILL.md`.
- `head -5 SKILL.md` to check the front matter; `wc -l SKILL.md` for length.
- `awk '/^description:/{print length($0)-13}' SKILL.md` to count description characters.
- `python3 -c "import sys,re;t=open(sys.argv[1]).read();print(bool(re.match(r'---\nname: [a-z0-9-]+\ndescription: Use when',t)))" SKILL.md` as a quick format check.
- `grep -nP '[^\x00-\x7F]' SKILL.md` finds curly quotes and long dashes; replace them with plain ASCII.

## Quality checklist

- Folder name and `name:` match exactly and use only lowercase letters, digits and hyphens.
- Description starts "Use when", names real trigger words, is under 220 characters.
- Steps are numbered, each one an action with a command, path or check.
- Every command was run at least once during testing, or is clearly marked as untested.
- No passwords, API keys, tokens or personal data inside the skill. Anything that sends, posts, buys or deletes says to wait for the user's yes.
- Pitfalls list real failures you saw, not generic advice.
- Ends with a `Based on:` line.

## Reply to the user

One or two sentences: the skill's name, what it is for, and that it is saved in the library, for example "I saved a skill called weekly-sales-report that rebuilds the Monday numbers from your Stripe export; it's on for this helper." Mention if it still needs a test on a real file.

## Pitfalls

- A vague description means the skill never loads. Write it for the moment of decision, with the user's words.
- Long essays get skimmed. Cut background; keep commands and checks.
- Copying a chat transcript into a skill. Distill it into steps.
- Hard-coding one file name or date that will be different next time. Use placeholders like `<export.csv>`.
- Two skills for the same job confuse helpers. Extend the existing one instead.
- Saving secrets from the conversation into the skill file. Never.

Based on: anthropics/skills "skill-creator"
