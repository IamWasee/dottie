---
name: commercial-script-and-shotlist
description: Use when the user wants a commercial, product ad, promo video or app demo spot planned: concept, script, voiceover, on-screen text and a timed shot list of what to record on the Mac.
---

# Commercial Script and Shot List

## When to use

- "Write a commercial for my app", "plan a 30-second ad", "make a promo video script", "what should I record for a product demo ad".
- The goal is selling or announcing one product or feature in a fixed length (6, 15, 30, 60 or 90 s).
- Not for creator videos (tutorials, vlogs): use `youtube-tiktok-scripts`.
- For editing the recorded footage: `screen-recording-edits`. For a still ad: `poster-and-graphics`.

## Steps

1. Brief, in `tmp/brief.md`: product, the one feature or promise, audience, where it runs (YouTube pre-roll, Instagram/TikTok, X, website hero, App Store preview), length, aspect ratio, tone, the CTA, and brand rules (`brand.md` if present). Use only facts the user gave or that are on their site.
2. Write 3 concepts, one line each plus a sentence on why it works:
   - Problem then solution (show the pain, then the product removing it).
   - Before and after (split screen or time jump).
   - Single magic moment (one jaw-drop interaction, repeated or slowed).
   Recommend one.
3. Time budget: about 2.3 spoken words per second for VO. 15 s is about 30 words, 30 s about 65. Leave the last 2 to 3 s for logo and CTA. App Store previews: 15 to 30 s, captured on the device, no hands or people.
4. Script: write `output/<slug>-commercial.md` with:
   - Title, length, aspect ratio(s), concept line.
   - Script table: Time (start-end), Visual, VO, On-screen text (max 6 words per card, readable for at least 1.5 s), Sound/music cue.
   - Opening 2 seconds must show the product or the problem with motion.
5. Shot list table, one row per shot: Shot #, Duration, Type (screen recording, UI close-up zoom, phone footage, title card, stock), Exactly what to do on screen (app state, window size, clicks, what to type), Setup notes, Status.
6. Mac recording plan for every screen shot:
   - Clean desktop: hide icons (`defaults write com.apple.finder CreateDesktop false; killall Finder`, revert with `true`), turn on Do Not Disturb, close unrelated apps, use demo data with no real names or emails.
   - Window size fixed per aspect: 1920x1080 for 16:9; for 9:16 record a narrower window centered so it crops cleanly.
   - Larger pointer if the cursor matters; slow, deliberate mouse moves; pause 1 s before and after each click.
   - Record each shot separately with 2 s of handle at both ends; name files `shot-01.mov`, `shot-02.mov` in `output/<slug>-footage/`.
7. Voiceover: final VO text in `output/<slug>-vo.txt`, plus a scratch read with `say` so the user hears the timing.
8. Deliverables list: master 16:9, cutdowns (15 s, 6 s bumper), vertical 9:16, square 1:1, captions SRT, thumbnail/end card.
9. Hand off to `screen-recording-edits` once footage exists.

## Tools on a Mac

- Scratch VO and timing: `say -v Samantha -r 165 -o tmp/vo.aiff -f output/<slug>-vo.txt && afinfo tmp/vo.aiff | grep duration`.
- Convert scratch VO for editing: `afconvert -f m4af -d aac tmp/vo.aiff output/<slug>-scratch-vo.m4a`.
- Screen recording (only after the user says go): `screencapture -v -C -V 12 output/<slug>-footage/shot-01.mov` (12-second cap, `-C` shows cursor).
- Window sizing: `osascript -e 'tell application "System Events" to tell process "Safari" to set size of front window to {1920, 1080}'` (needs Accessibility permission).
- Do Not Disturb: suggest the user turns on a Focus; `shortcuts run "<their focus shortcut>"` if they have one.
- Word count: `wc -w output/<slug>-vo.txt`.
- Storyboard frames: quick HTML or SVG frames rendered to PNG (see `poster-and-graphics`), saved as `output/<slug>-storyboard/frame-NN.png`.

## Quality checklist

- The product appears in the first 3 seconds and the brand/logo at the end.
- One message only; the CTA is one action with the exact URL or store name.
- VO word count fits the length; on-screen text readable at phone size.
- Every shot in the script has a row in the shot list with concrete on-screen actions.
- Shot durations add up to the total length.
- No invented claims (awards, user counts, "number one"), no competitor names, no real personal data in demo screens.
- Works with sound off (captions or on-screen text carry the message).

## Reply to the user

One to three sentences: the concept, the length, the paths, e.g. "Planned a 30-second 'single magic moment' ad with 7 shots and a 64-word voiceover. Script and shot list are in output/notes-ad-commercial.md; play tmp/vo.aiff to hear the timing."

## Pitfalls

- Too many features for the length; a 30 s ad sells one thing.
- Scripts where the visuals just repeat the VO word for word.
- Recording at different window sizes per shot, which makes crops jump.
- Shots with no handles, so cuts feel abrupt.
- Licensed music or stock assumed free; list them as to-license.
- Recording the screen, publishing or buying ads without the user's yes.

Based on: written for Dottie
