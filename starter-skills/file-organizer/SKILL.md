---
name: file-organizer
description: Use when the user wants a messy folder tidied: "clean up my Downloads", "organize my Desktop", "sort these files", "find duplicates". Plans first, moves instead of deleting, keeps an undo log.
---

# File Organizer

## When to use

- Tidying Downloads, Desktop, Documents or any folder the user names.
- Sorting files into folders by type, project or date.
- Finding duplicate files and large old files.
- Not for notes inside a Markdown vault: use `markdown-notes-vault`.
- Never for system folders (`/System`, `/Library`, `~/Library`) or app bundles.

## Steps

1. Scope. Work only in the folder the user named. Note it as `$TARGET`. Do not recurse into subfolders unless asked; treat existing subfolders as already organized.
2. Survey, read-only:
   - Count and size: `find "$TARGET" -maxdepth 1 -type f | wc -l` and `du -sh "$TARGET"`.
   - By extension: `find "$TARGET" -maxdepth 1 -type f | sed -E 's/.*\.([^.]+)$/\1/' | tr A-Z a-z | sort | uniq -c | sort -rn`.
   - Largest: `find "$TARGET" -maxdepth 1 -type f -size +100M -exec ls -lh {} \;`.
   - Oldest untouched: `find "$TARGET" -maxdepth 1 -type f -atime +180`.
3. Find duplicates by content, not name (see Tools). Same size first, then hash.
4. Write the plan to `output/organize-plan.md`: proposed folders, how many files go where, duplicate groups (which copy is kept: the oldest or the one with the clearest name), and anything you will not touch. Suggested buckets for Downloads: `Documents`, `Images`, `Installers` (.dmg .pkg .zip of apps), `Archives`, `Audio`, `Video`, `Spreadsheets`, `Code`, `To review`.
5. Stop and show the plan. Reply with the summary and wait for the user's yes before moving anything.
6. On yes, move with `mv -n` (never overwrite). For every move append a line to `output/organize-undo.sh`: `mv -n "<new path>" "<old path>"`. Duplicates go to `$TARGET/_Duplicates/`, not the Trash.
7. Deleting: only if the user explicitly says delete, and then to the Trash so it is recoverable: `osascript -e 'tell application "Finder" to delete POSIX file "/full/path"'`. Never `rm`.
8. Verify: file count before equals file count after (across the new folders); run `ls` on each new folder.

## Tools on a Mac

- Hash for duplicates: `shasum -a 256 "$file"`. For a whole folder, group same-size files first, then hash only those:

```bash
python3 - "$TARGET" <<'PY'
import hashlib, os, sys, collections
by_size = collections.defaultdict(list)
for name in os.listdir(sys.argv[1]):
    path = os.path.join(sys.argv[1], name)
    if os.path.isfile(path): by_size[os.path.getsize(path)].append(path)
for paths in by_size.values():
    if len(paths) < 2: continue
    by_hash = collections.defaultdict(list)
    for path in paths:
        by_hash[hashlib.sha256(open(path, "rb").read()).hexdigest()].append(path)
    for group in by_hash.values():
        if len(group) > 1: print(" | ".join(group))
PY
```

- File kind and dates: `mdls -name kMDItemKind -name kMDItemContentCreationDate -name kMDItemWhereFroms "$file"` (WhereFroms tells where a download came from).
- Date taken for photos: `mdls -name kMDItemContentCreationDate photo.jpg` or `sips -g creation photo.jpg`.
- Safe move: `mkdir -p "$TARGET/Images" && mv -n "$file" "$TARGET/Images/"`.
- Undo: run the log newest move first, `tail -r output/organize-undo.sh | sh`.
- Reveal the result if the user asks: `open "$TARGET"`.

## Quality checklist

- The plan was shown and approved before any move.
- File count unchanged after moving; nothing deleted without an explicit request.
- Every move is in `output/organize-undo.sh`.
- No file overwritten (`mv -n`), no hidden files or app bundles moved.
- Duplicates kept one copy in place and moved the rest to `_Duplicates/`.

## Reply to the user

Plan stage: one to three sentences with the numbers, then the question. For example: "Downloads has 412 files; I'd sort them into 7 folders and set aside 38 duplicates (1.2 GB). The plan is in output/organize-plan.md. Go ahead?" After moving: what moved and that `output/organize-undo.sh` puts it all back.

## Pitfalls

- Moving files an app is still downloading (`.crdownload`, `.download`, `.part`): skip them.
- Matching duplicates by name ("report (1).pdf") instead of content; names lie.
- Moving `.app` bundles or folders that look like files (packages such as `.pages`, `.key`, `.photoslibrary`) breaks them; treat any directory as off-limits.
- iCloud "optimized" files are placeholders; hashing them downloads them. Skip files whose `mdls` shows they are not local, or warn about the download size.
- Desktop and Documents may sync to iCloud; huge moves cause long syncs. Mention it.
- Never empty the Trash.

Based on: ComposioHQ/awesome-claude-skills "file-organizer"
