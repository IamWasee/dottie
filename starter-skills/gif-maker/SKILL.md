---
name: gif-maker
description: Use when the user wants a GIF, looping animation, reaction GIF, sticker or emoji animation from a video, screen recording or images, or needs a GIF small enough for Slack, Discord or GitHub.
---

# GIF Maker

## When to use

- "Make a GIF of this", "turn this clip into a GIF", "a looping sticker", "an animated Slack emoji", "make it small enough for Discord".
- Input is a video, a screen recording, a set of frames, or a drawing you generate frame by frame.
- Not for a long video edit: use `video-editing-ffmpeg`. Not for a still image: use `poster-and-graphics` or `image-editing`.

## Steps

1. Check tools: `ffmpeg -version` (`brew install ffmpeg` if missing). `gifsicle` is optional for squeezing size (`brew install gifsicle`).
2. Find the target and its limits:
   - Slack custom emoji: 128x128 recommended, under 128 KB (bigger uploads may get resized or rejected).
   - Slack message GIF: aim under 2 to 5 MB and 480 to 640 px wide.
   - Discord: emoji 128x128 under 256 KB; stickers APNG/GIF 320x320 under 512 KB; message attachments 10 MB on free accounts.
   - GitHub README: under 10 MB, 800 px wide is plenty.
   - If unsure, default to 480 px wide, 12 to 15 fps, under 3 seconds, under 2 MB.
3. Pick the moment: a short section (1 to 4 s) that loops well. Find start and end with `ffprobe` and a few test frames.
4. Make it with the two-pass palette method (best quality per byte), output to `output/<name>.gif`.
5. Check size with `ls -lh`. If over the limit, shrink in this order: fewer seconds, smaller width, lower fps, fewer colors, then `gifsicle --lossy`.
6. For a perfect loop, cut on matching frames, or make a boomerang (forward then reverse).
7. For animations drawn from scratch: render numbered PNG frames into `tmp/frames/` (Python + Pillow, or HTML screenshots), then assemble.
8. Open the result and watch it loop at least twice.

## Tools on a Mac

- Two-pass high quality GIF:
  `ffmpeg -ss 2.0 -t 3 -i in.mp4 -vf "fps=15,scale=480:-1:flags=lanczos,palettegen=stats_mode=diff" -y tmp/palette.png`
  `ffmpeg -ss 2.0 -t 3 -i in.mp4 -i tmp/palette.png -lavfi "fps=15,scale=480:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" -loop 0 -y output/clip.gif`
- One-line version: `-filter_complex "[0:v]fps=15,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" -loop 0`.
- Square emoji: add `crop=min(iw\,ih):min(iw\,ih),scale=128:128` before `palettegen`/`paletteuse`.
- Fewer colors: `palettegen=max_colors=64`.
- Boomerang: `-filter_complex "[0:v]trim=0:2,setpts=PTS-STARTPTS,split[f][r];[r]reverse[rv];[f][rv]concat=n=2:v=1,fps=15,scale=480:-1,split[a][b];[a]palettegen[p];[b][p]paletteuse"`.
- From frames: `ffmpeg -framerate 12 -i tmp/frames/%03d.png -vf "split[a][b];[a]palettegen[p];[b][p]paletteuse" -loop 0 output/anim.gif`.
- Squeeze: `gifsicle -O3 --lossy=60 --colors 128 output/clip.gif -o output/clip-small.gif`; resize `gifsicle --resize-width 320`.
- Text overlay: `drawtext=fontfile=/System/Library/Fonts/Helvetica.ttc:text='Ship it':fontsize=36:fontcolor=white:borderw=3:x=(w-text_w)/2:y=h-th-20` before `palettegen`.
- Transparent sticker: GIF transparency is 1-bit; for smooth edges use APNG `ffmpeg -i in.mov -plays 0 -f apng output/sticker.png` or animated WebP `-c:v libwebp -loop 0 -lossless 0 -q:v 70 output/sticker.webp`.
- MP4 instead of GIF (far smaller, for platforms that autoplay video): `ffmpeg -i in.mp4 -an -vf scale=480:-2 -c:v libx264 -crf 26 -pix_fmt yuv420p -movflags +faststart output/clip.mp4`.
- Watch it: `open -a Safari output/clip.gif` (Preview shows frames, not playback); `qlmanage -p output/clip.gif`.
- Info: `gifsicle --info output/clip.gif | head -5`.

## Quality checklist

- Under the size limit for where it is going (`ls -lh`).
- Loops cleanly with no visible jump or flash frame.
- No heavy banding or dither noise on flat areas; text is readable.
- Correct dimensions (square for emoji).
- Plays at a natural speed (12 to 20 fps for real footage, 8 to 12 fine for simple motion).
- Starts and ends on the moment the user wanted.

## Reply to the user

One to three sentences with path, size and dimensions, e.g. "Here's a 3-second loop at 480 px, 1.4 MB, small enough for Slack: output/high-five.gif."

## Pitfalls

- Single-pass GIF without a palette looks grainy and is larger.
- `scale=-1` can give odd heights that some tools reject; `-2` keeps it even for MP4 (GIF is fine with odd).
- Long GIFs explode in size; 10 seconds at 640 px is often 20 MB or more.
- Previewing in Preview.app and thinking it does not animate.
- Using copyrighted clips as public stickers; uploading anything without the user's yes.

Based on: anthropics/skills "slack-gif-creator"
