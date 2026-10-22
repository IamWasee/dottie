---
name: youtube-tiktok-scripts
description: Use when the user wants a script, hook, outline, titles or thumbnail ideas for a YouTube video, TikTok, Reel, Short or other short-form or long-form creator video.
---

# YouTube and TikTok Scripts

## When to use

- "Write a TikTok script about", "script my YouTube video", "give me hooks", "title and thumbnail ideas", "turn this blog post into a Short".
- Creator content: tutorials, explainers, reviews, vlogs, storytime, listicles.
- Not for a paid ad or product commercial with a shot list: use `commercial-script-and-shotlist`.
- For editing the footage afterwards: `video-editing-ffmpeg` or `screen-recording-edits`. For the thumbnail image itself: `poster-and-graphics`.

## Steps

1. Pin down: platform and length (Short/TikTok/Reel 15 to 60 s, up to 3 min; YouTube long-form 6 to 15 min), topic, audience, the one takeaway, the call to action, and the creator's on-camera style (talking head, voiceover, screen recording, faceless).
2. If facts are involved, research with web search and keep source links in `tmp/sources.md`. Do not invent stats.
3. Write 5 hooks, each a different type, and pick the best:
   - Outcome ("This one setting doubled my battery life").
   - Curiosity gap ("Nobody tells you why ... ").
   - Contrarian ("Stop using to-do lists").
   - Pattern interrupt (a surprising visual in the first frame).
   - Direct callout ("If you edit on a Mac, watch this").
   The hook must land in the first 2 seconds (about 5 to 7 spoken words) with the visual already moving.
4. Short-form structure (about 2.5 words per second, so 30 s is 70 to 80 words):
   - 0 to 2 s hook, 2 to 5 s stakes or promise, then 3 to 5 beats of one idea each, a payoff, and a quick CTA. Cut every sentence that does not move it forward. Optional loop: last line leads back into the first.
5. Long-form structure: cold open hook (0 to 15 s) that shows the payoff, a 15 to 30 s promise of what they will get, chapters each opening with an open question and closing with a mini-payoff, a re-hook every 60 to 90 s, a mid-roll CTA only after delivering value, an ending that pays off the title without a long goodbye.
6. Write the script as a table in `output/<slug>-script.md` with columns: Time, Spoken words (VO / on camera), On-screen visual or b-roll, On-screen text (caption, max 6 words).
7. Add a b-roll and shot list: each shot, where it comes from (record on Mac, phone, stock, screen recording), and duration.
8. Add captions guidance: burned-in captions for short-form, 1 to 3 words per card for punchy styles, keep in the middle third away from UI overlays.
9. Add 5 titles (under 60 characters, specific, no clickbait the video does not pay off) and 3 thumbnail concepts (subject, expression or object, 2 to 4 words of text, contrast colors). For Shorts/TikTok add a caption and 3 to 5 hashtags.
10. Add retention notes: where viewers may drop and what fixes it (cut, visual change, new question).
11. Read the script aloud with `say` to check timing.

## Tools on a Mac

- Timing check: `say -r 170 -f tmp/vo.txt -o tmp/vo.aiff && afinfo tmp/vo.aiff | grep duration` (170 wpm is a brisk creator pace).
- Word count: `wc -w tmp/vo.txt`.
- Copy the spoken lines to paste into a teleprompter: `pbcopy < tmp/vo.txt`.
- Research: web search and fetch; transcripts of the user's own past videos if they give links.
- Word file if asked: `textutil` does not read Markdown, so write the script as `tmp/script.html` and run `textutil -convert docx tmp/script.html -output output/<slug>-script.docx`.
- Preview: `open output/<slug>-script.md`.

## Quality checklist

- Hook works with sound off (on-screen text) and in under 2 seconds.
- One clear takeaway; every beat earns its place.
- Spoken word count fits the target length.
- Every line has a visual; no 5-second stretches of the same shot.
- Facts have sources; no invented numbers or quotes.
- Titles and thumbnails promise only what the video delivers.
- CTA is one action, not three.

## Reply to the user

One to three sentences: the hook you chose, the length, the path, e.g. "Wrote a 45-second TikTok script opening with 'Your Mac has a hidden screen recorder' plus 5 titles and a b-roll list: output/mac-recorder-script.md."

## Pitfalls

- Slow intros ("Hey guys, welcome back") before the hook.
- Writing for reading instead of speaking: long sentences, nested clauses.
- Over-packing a Short with several ideas.
- Clickbait titles that hurt retention when the video does not deliver.
- Using music or clips without rights; posting anything without the user's yes.

Based on: written for Dottie
