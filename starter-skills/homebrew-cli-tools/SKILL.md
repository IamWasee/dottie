---
name: homebrew-cli-tools
description: Use when a task needs a command-line tool that isn't installed ("command not found", "install ffmpeg", "get me a tool for X"), or the user asks what was installed with Homebrew.
---

# Homebrew CLI Tools

## When to use

- A command you need is missing (`command not found`) and a well-known tool solves it: ffmpeg, pandoc, yt-dlp, tesseract, jq, imagemagick, poppler, ripgrep.
- The user asks to install, update or remove a command-line tool.
- The user asks what you installed.
- Not for Mac apps from the App Store or paid software: tell the user what to get instead.
- Prefer a built-in first (`sips`, `textutil`, `afconvert`, `qlmanage`, `curl`, `python3`). Install only if built-ins can't do the job well.

## Steps

1. Check before installing: `command -v toolname` and `brew list --formula | grep -x toolname`. If it exists, use it.
2. Check Homebrew itself: `command -v brew`. On Apple silicon it lives at `/opt/homebrew/bin/brew`, on Intel at `/usr/local/bin/brew`. If it is missing, do not install Homebrew yourself: tell the user it needs their admin password and give them the one line from brew.sh to paste in Terminal.
3. Find the right formula: `brew search name` then `brew info name`. Prefer the formula with many installs and a known homepage. Check `brew info --json=v2 name | python3 -c "import json,sys;d=json.load(sys.stdin)['formulae'][0];print(d['desc'],d['homepage'])"`.
4. Avoid unknown taps (`brew tap someone/thing`) and casks for GUI apps unless the user asked for that app by name.
5. Install: `brew install name`. It can take minutes; let it finish. Don't run `brew upgrade` on everything as a side effect; that changes other tools the user relies on.
6. Verify: `name --version`, then run the real command once on a small input.
7. Keep a note: append one line to `output/installed-tools.md` (create it if missing) with date, formula, version and why, for example `2026-10-22  ffmpeg 7.1  converting the user's screen recordings`.
8. Uninstalling or upgrading tools the user already had waits for their yes.

## Tools on a Mac

- `brew search <term>`, `brew info <formula>`, `brew install <formula>`, `brew list --versions`
- `brew uses --installed <formula>` before removing anything (shows what depends on it).
- `brew uninstall <formula>`, `brew upgrade <formula>` (one at a time, with the user's yes).
- `brew doctor` when installs fail; read its first warnings only.
- `brew install --dry-run <formula>` (recent Homebrew) shows what would be pulled in without installing.
- `brew deps --tree <formula>` to see how heavy an install will be.
- `brew --prefix` to find where things live.
- `brew outdated <formula>` to see if one tool is behind, without touching others.
- `brew cleanup <formula>` frees space from old versions of that one formula.
- For Python packages: `python3 -m pip install --user <package>` for well-known ones (requests, pillow, python-docx). If pip refuses with "externally managed", use `brew install pipx` then `pipx install <tool>` for CLI tools.
- Well-known formulae by job: media `ffmpeg`; documents `pandoc`, `poppler` (pdftotext, pdftoppm), `qpdf`; images `imagemagick`, `exiftool`; OCR `tesseract`; data `jq`, `csvkit`, `sqlite`; web `wget`, `yt-dlp`; search `ripgrep`, `fd`.

## Quality checklist

- Checked it was not already installed.
- The formula is the well-known one (core tap, real homepage), not a look-alike.
- Version printed and a real test run passed.
- The note in `output/installed-tools.md` was added.
- No `sudo`, no piping random scripts into a shell, no system-wide upgrades.

## Reply to the user

One sentence: what you installed and why, for example "I installed ffmpeg with Homebrew to convert the videos; it's noted in output/installed-tools.md." If Homebrew is missing, say that plainly and what they need to do.

## Pitfalls

- `brew install` auto-updates Homebrew first and can be slow; that is normal. `HOMEBREW_NO_AUTO_UPDATE=1 brew install x` skips it when time matters.
- PATH: a fresh install may not be on the helper's PATH. Call it by full path (`/opt/homebrew/bin/ffmpeg`) if `command -v` fails right after install.
- Name clashes: `brew install imagemagick` gives `magick`, not `convert` on newer versions; `poppler` gives `pdftotext`, not a `poppler` command.
- Never use `sudo brew`. It breaks permissions.
- `brew search` matches loosely; `brew info` on the exact name before installing avoids grabbing a fork or a cask by mistake.
- A tool may already exist under another manager (pip, npm, a download in `~/bin`); check `which -a name` before adding a second copy.
- Casks (`--cask`) install GUI apps and may ask for a password; leave those to the user.
- Big installs (like `ffmpeg` with many dependencies) pull hundreds of MB; mention it if the user is on a slow connection.

Based on: written for Dottie
