---
name: video-game-guides
description: Use when the user wants help with a video game or Roblox experience: "how do I play X", "make me a guide for this game", "what are the controls", "best first steps in X", "how do I beat this boss".
---

# Video Game Guides

## When to use

- Writing a short starter guide for a game or Roblox experience the user is about to play or is stuck in.
- Answering a focused question (a boss, a quest, a crafting recipe, a control) with sources.
- Not for long lore essays or full walkthroughs; keep the guide to what helps the next hour of play.

## Steps

1. Pin down the exact game: full title, platform (PC, console, mobile, Roblox), and version or season if it matters. Roblox experiences need the experience name and creator, since many share names.
2. Search in this order and open the best two or three:
   - The official site, patch notes or Steam page (for current controls and mechanics).
   - The official or main wiki (Fandom or a dedicated wiki like wiki.gg). Prefer the one with recent edits.
   - Reddit (`site:reddit.com <game> beginner tips`) for what players actually recommend now.
   - YouTube guides: read titles, descriptions and transcripts rather than watching. Prefer recent ones.
   - Roblox: the experience page (description, updates), its Discord or Trello linked from that page, and its wiki if it has one.
3. Check dates. Patches change builds, prices and controls. Prefer sources from the current version; note anything that may be outdated.
4. Write `output/game-guide.md` (or `output/<game>-guide.md` if one already exists for a different game) with these sections, short and scannable:
   - **Game**: title, platform, version checked, date.
   - **Controls**: a table of key or button and action, default bindings for the user's platform.
   - **Goal**: what you are trying to do, in two or three sentences.
   - **First hour**: a numbered route, 5 to 10 steps.
   - **Tips**: 5 to 8 that save the most time or deaths.
   - **Avoid**: common beginner mistakes.
   - **Roblox specifics** (Roblox only): game passes and what is free, codes from the official page (with date checked), trading and scam warnings, private server notes.
   - **Sources**: links used.
5. Cross-check any number (damage, prices, drop rates, codes) against a second source; drop it if they disagree and you can't tell which is current.

## Tools on a Mac

- Web search and fetch for pages; `curl -sL URL | textutil -stdin -format html -convert txt -stdout` to read a page as text.
- `brew install yt-dlp`, then `yt-dlp --skip-download --write-auto-subs --sub-langs en --convert-subs srt -o "tmp/%(id)s" URL` for a YouTube transcript.
- `open output/game-guide.md` to show the file.
- `screencapture -x tmp/game.png` plus the `screenshot-ocr` skill if the user asks about what's on screen right now.

## Quality checklist

- Right game and platform; controls match that platform.
- Every claim about current content comes from a source dated near the current version.
- Codes and prices listed with the date checked.
- First-hour route is something a new player can actually follow in order.
- The guide fits on about one screen per section; no padding.
- Sources listed.

## Reply to the user

One or two sentences with the single most useful tip and the path, for example "Your Grow a Garden guide is in output/game-guide.md; the big one is to sell crops before the shop restocks." Spoken aloud, so no tables or lists in the reply.

## Pitfalls

- Wikis for games with similar names (or Roblox clones of popular experiences). Check the creator and links.
- Outdated tier lists and meta builds after a patch.
- Roblox "free Robux" or code generator sites are scams; never link them. Codes only from the experience's own page, Discord or social accounts.
- Cheats, exploits, scripts and account sharing: don't help; they risk bans.
- Spoilers: keep story spoilers out unless the user asked.
- Don't buy, trade, or join anything on the user's behalf.

Based on: written for Dottie
