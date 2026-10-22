---
name: markdown-notes-vault
description: Use when the user keeps notes in a Markdown folder or Obsidian vault and wants notes added, linked, tagged, found or tidied: "add to my notes", "daily note", "find my note about".
---

# Markdown Notes Vault

## When to use

- Adding a note, a daily note, or a clipping to a folder of Markdown notes (Obsidian, Logseq-style, iA Writer or plain folders).
- Finding notes by text, tag, link or date.
- Linking related notes, fixing broken links, adding front matter, building index notes.
- Not for moving or renaming many non-note files: use `file-organizer`.
- Not for writing a long document: use `doc-coauthoring`, then save the result into the vault.

## Steps

1. Find the vault. Use the path the user gives. Otherwise look for a `.obsidian` folder: `mdfind -name .obsidian 2>/dev/null | head` or check `~/Documents`, `~/Obsidian`, iCloud at `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/`. Confirm the path in your reply the first time.
2. Learn its conventions before writing: list folders (`ls`), read 3 recent notes (`ls -t **/*.md | head`), and check `.obsidian/daily-notes.json` and `.obsidian/templates.json` for the daily note folder, date format and template. Copy what the vault already does.
3. Write notes in this shape unless the vault does something else:

```markdown
---
title: Kitchen renovation
created: 2026-10-22
tags: [home, projects]
aliases: [kitchen reno]
---

# Kitchen renovation

Short summary line.

- Quote from [[Sam Builders]] due Friday
- See also [[Home budget 2026]]
```

4. File names: the title in plain words, `Kitchen renovation.md`; no dates in the name except daily notes (`2026-10-22.md` in the daily folder).
5. Links: use `[[Note name]]` for notes that exist or should exist; check the target exists with `ls`, and create a stub if the user wants it. Use `[[Note name#Heading]]` for sections.
6. Tags: lowercase, hyphenated, few. Reuse existing tags; list them first (see Tools).
7. Daily note: append under a heading (`## Log`, or whatever the template uses) with a time stamp; create the note from the template if it does not exist.
8. Edit by appending or inserting; never rewrite a whole note the user wrote.

## Tools on a Mac

- Search text: `rg -n -i "renovation" "$VAULT" --glob '*.md'` (`brew install ripgrep`; fallback `grep -rni`).
- Find by tag: `rg -n "(^tags:.*\bhome\b|#home\b)" "$VAULT" --glob '*.md'`.
- List all tags: `rg -o --no-filename "#[a-z][a-z0-9/_-]+" "$VAULT" --glob '*.md' | sort | uniq -c | sort -rn | head -40`.
- Backlinks to a note: `rg -l "\[\[Kitchen renovation(\|[^]]*)?(#[^]]*)?\]\]" "$VAULT"`.
- Broken links: extract `[[...]]` targets with `rg -o --no-filename "\[\[[^]|#]+" "$VAULT" | sort -u` and compare with `find "$VAULT" -name '*.md'` basenames.
- Recent notes: `find "$VAULT" -name '*.md' -mtime -7 -not -path '*/.obsidian/*'`.
- Spotlight search across the vault: `mdfind -onlyin "$VAULT" "renovation"`.
- Today's date: `date +%Y-%m-%d`; time: `date +%H:%M`.
- Open a note in Obsidian if asked: `open "obsidian://open?path=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$NOTE_PATH")"`.

## Quality checklist

- Front matter is valid YAML (dashes on their own lines, lists in brackets or dashes, colons in values quoted).
- New links point at notes that exist, or the stub was created on purpose.
- Tags reuse existing ones; no near-duplicates (`project` vs `projects`).
- File name has no `/ \ : * ? " < > |` and no `#`, `^`, `[`, `]`.
- Nothing outside the vault changed; no note the user wrote lost text.

## Reply to the user

One or two sentences: what you added or found, and where. For example: "Added today's log entry to Daily/2026-10-22.md and linked it to Kitchen renovation." For searches, name the top one to three notes.

## Pitfalls

- Editing `.obsidian/` settings or plugin files. Leave them alone.
- Writing while Obsidian Sync or iCloud is mid-sync can create "conflicted copy" files; write once, do not rewrite rapidly.
- Renaming a note breaks every `[[link]]` to it; if you must rename, update the links with care and list them.
- Using Markdown links `[x](x.md)` in a vault that uses wikilinks, or the other way round.
- Inventing a folder layout the user does not use.
- Large vaults: always scope searches to `*.md` and skip `.obsidian`, `.trash` and attachments.

Based on: written for Dottie
