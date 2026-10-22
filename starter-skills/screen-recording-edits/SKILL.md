---
name: screen-recording-edits
description: Use when the user wants to turn a screen recording into a polished demo, tutorial, product video or commercial clip: cut dead time, zoom in, add captions, music and a clean export.
---

# Screen Recording Edits

## When to use

- "Clean up this screen recording", "make a demo video from this", "cut the boring parts", "zoom in on the button", "add captions and music", "make it a commercial clip".
- Input is a `.mov` or `.mp4` from QuickTime, `screencapture -v`, Cmd+Shift+5, or another recorder.
- Not for simple trims or conversions: use `video-editing-ffmpeg`. For planning what to record: use `commercial-script-and-shotlist`.

## Steps

1. Inspect: `ffprobe -v error -show_entries format=duration:stream=width,height,r_frame_rate,codec_name -of compact rec.mov`. Retina recordings are often 2880x1800 or larger at 60 fps.
2. Find dead time:
   - Silence: `ffmpeg -i rec.mov -af silencedetect=noise=-35dB:d=1.2 -f null - 2>&1 | grep silence_`.
   - Frozen screen: `ffmpeg -i rec.mov -vf "freezedetect=n=0.003:d=1.5" -map 0:v -f null - 2>&1 | grep freeze_`.
   - Gaps that are both silent and frozen are safe to cut. Keep 0.3 s of padding on each side.
3. Write an edit decision list in `tmp/edl.csv`: `start,end,zoom_x,zoom_y,zoom_w,caption`. Times in seconds of the source. Leave zoom empty for full frame.
4. Zoom crops: for each moment where the action is small, crop to a 16:9 region around it (at least 1/3 of the frame width so it is not blurry) and scale back up: `crop=960:540:1200:300,scale=1920:1080:flags=lanczos`. Use a cut into the zoom, or a smooth push-in with `zoompan` only on short segments.
5. Cursor: if the cursor is too small, recommend re-recording with a larger pointer (System Settings > Accessibility > Display > Pointer size). Cursor highlights or click rings need the click times; add them with a PNG ring overlaid `enable='between(t,a,b)'`.
6. Render each segment to `tmp/seg-NN.mp4` with identical settings (1920x1080, 30 fps, H.264 CRF 18, AAC 48 kHz), then join with the concat demuxer.
7. Captions: transcribe the voiceover to SRT (whisper), fix names and terms by hand, keep lines under 42 characters and 2 lines, then burn in.
8. Music and ducking: lower music under speech with sidechain compression (see Tools). Music only if the user supplied it or it is clearly royalty-free.
9. Add a 0.5 s fade in and out, normalize loudness, and export the presets the user needs.
10. Watch the full result once, start to end, before replying.

## Tools on a Mac

- Record (if asked, after the user says go): `screencapture -v -C -k output/rec.mov` (`-C` cursor, `-k` show clicks); stop with Ctrl+C or via `-V <seconds>`.
- Segment render: `ffmpeg -ss <a> -to <b> -i rec.mov -vf "fps=30,crop=W:H:X:Y,scale=1920:1080:flags=lanczos,format=yuv420p" -c:v libx264 -crf 18 -preset slow -c:a aac -b:a 192k -ar 48000 tmp/seg-01.mp4`
- Join: `ffmpeg -f concat -safe 0 -i tmp/list.txt -c copy tmp/joined.mp4`.
- Captions: `whisper tmp/joined.mp4 --model small --output_format srt --output_dir tmp` (`python3 -m pip install --user openai-whisper`), then `-vf "subtitles=tmp/joined.srt:force_style='FontName=Helvetica Neue,FontSize=20,PrimaryColour=&HFFFFFF&,OutlineColour=&H80000000&,BorderStyle=3,MarginV=40'"`.
- Music ducking: `ffmpeg -i tmp/joined.mp4 -i music.m4a -filter_complex "[1:a]volume=0.35[m];[m][0:a]sidechaincompress=threshold=0.03:ratio=10:attack=20:release=400[duck];[0:a][duck]amix=inputs=2:duration=first:normalize=0,loudnorm=I=-14:TP=-1.5[a]" -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k output/demo.mp4`
- Voiceover placeholder: `say -v Samantha -o tmp/vo.aiff -f tmp/vo.txt`, then `afconvert -f m4af -d aac tmp/vo.aiff tmp/vo.m4a`.
- Title card: render a 1920x1080 PNG (see `poster-and-graphics`), then `ffmpeg -loop 1 -t 2 -i title.png -f lavfi -t 2 -i anullsrc=r=48000:cl=stereo -vf format=yuv420p -c:v libx264 -c:a aac tmp/seg-00.mp4`.
- Export presets:
  - Web/YouTube 16:9: 1920x1080, 30 fps, CRF 18, `-movflags +faststart`, loudnorm -14.
  - Vertical social: 1080x1920 with the demo scaled to width over a blurred or brand-color background, captions in the middle third.
  - Square: 1080x1080. Small share: 1280x720 CRF 26, under 25 MB.
- Check: `open output/demo.mp4`.

## Quality checklist

- No pauses over about 1 second without something happening on screen or in audio.
- Every zoomed segment is sharp (crop at least 960 px wide on a 1920 output).
- Captions match the words, with correct product names, and never cover the UI being shown.
- Music is quieter than speech everywhere; no clipping; loudness near -14 LUFS.
- No private info visible: emails, notifications, tokens, other tabs, desktop files. Blur with `boxblur` on a crop overlay if needed, and tell the user.
- Exports match the requested platforms and play in QuickTime.

## Reply to the user

One to three sentences: length before and after, what was added, paths, e.g. "Cut your 6-minute recording to a 1:48 demo with 4 zooms, captions and ducked music: output/demo-16x9.mp4 and output/demo-9x16.mp4."

## Pitfalls

- Mixing segments with different fps or sizes, which breaks the concat or desyncs audio.
- Zooming into regions so small the text turns to mush.
- Cutting mid-word; keep padding around speech.
- Leaving notifications or personal data on screen.
- Variable frame rate from screen recorders; force `fps=30` on every segment.
- Starting a recording or posting the video without the user's yes.

Based on: written for Dottie
