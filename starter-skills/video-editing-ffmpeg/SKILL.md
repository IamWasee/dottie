---
name: video-editing-ffmpeg
description: Use when the user wants to trim, cut, join, convert, compress, resize, speed up, crop to vertical, add subtitles or music, or extract audio from a video file, or make it fit a social platform.
---

# Video Editing with ffmpeg

## When to use

- "Trim this video", "join these clips", "make it smaller", "convert MOV to MP4", "make it vertical for TikTok", "add captions", "pull the audio out", "speed it up 2x".
- Not for turning a screen recording into a polished demo with zooms and ducked music: use `screen-recording-edits`.
- Not for short looping animations: use `gif-maker`.
- Not for writing the script: use `youtube-tiktok-scripts` or `commercial-script-and-shotlist`.

## Steps

1. Check ffmpeg: `ffmpeg -version`; if missing, `brew install ffmpeg`.
2. Inspect the input: `ffprobe -v error -show_entries format=duration:stream=codec_name,width,height,r_frame_rate,sample_rate -of compact in.mov`. Note rotation, frame rate and whether there is audio.
3. Plan the command and write it to `tmp/edit.sh` so it can be rerun. Write results to `output/`, never over the input.
4. Run on a short section first (`-t 10`) when the job is long, check it, then do the full file.
5. Verify the output with `ffprobe` (duration, size, codec) and open it with `open output/x.mp4` or `qlmanage -p`.

## Tools on a Mac

Common recipes (H.264 + AAC MP4 plays everywhere):
- Trim, exact: `ffmpeg -ss 00:00:05 -to 00:00:32 -i in.mp4 -c:v libx264 -crf 20 -preset medium -c:a aac -b:a 160k output/trim.mp4`
- Trim, instant (cuts on keyframes, may be off by a second): `ffmpeg -ss 5 -to 32 -i in.mp4 -c copy output/trim.mp4`
- Convert MOV to MP4: `ffmpeg -i in.mov -c:v libx264 -crf 20 -pix_fmt yuv420p -c:a aac -movflags +faststart output/out.mp4`
- Compress: raise `-crf` (23 to 28 = smaller) and cap size with `-vf "scale=-2:1080"`. To hit a size, bitrate = target MB x 8192 / seconds minus audio kbps; then `-b:v <n>k -maxrate <n>k -bufsize <2n>k`.
- Hardware encode (fast, bigger files): `-c:v h264_videotoolbox -b:v 8M` or `hevc_videotoolbox -tag:v hvc1`.
- Join same-format clips: write `tmp/list.txt` lines `file '/full/path/a.mp4'`, then `ffmpeg -f concat -safe 0 -i tmp/list.txt -c copy output/joined.mp4`. Different formats: re-encode each to the same size, fps and codec first.
- Vertical 9:16 center crop: `-vf "crop=ih*9/16:ih,scale=1080:1920"`. Blurred-background fit instead: `-filter_complex "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=20[bg];[0:v]scale=1080:-2[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2"`.
- Speed 2x: `-filter_complex "[0:v]setpts=0.5*PTS[v];[0:a]atempo=2.0[a]" -map "[v]" -map "[a]"` (atempo takes 0.5 to 2.0 per stage; chain for more).
- Extract audio: `ffmpeg -i in.mp4 -vn -c:a aac -b:a 192k output/audio.m4a`, or `-vn -c:a libmp3lame -q:a 2 output/audio.mp3`, or WAV `-vn -c:a pcm_s16le output/audio.wav`.
- Remove audio: `-an`. Replace audio: `ffmpeg -i v.mp4 -i music.m4a -map 0:v -map 1:a -c:v copy -shortest output/out.mp4`.
- Burn subtitles: `ffmpeg -i in.mp4 -vf "subtitles=subs.srt:force_style='FontName=Helvetica,FontSize=18,Outline=2,MarginV=60'" -c:a copy output/captioned.mp4`. Soft subtitles in MP4: `-i subs.srt -c copy -c:s mov_text`.
- Make an SRT: transcribe with `whisper in.mp4 --model small --output_format srt` (`python3 -m pip install --user openai-whisper`, runs locally) or `whisper-cli` from `brew install whisper-cpp`.
- Thumbnail frame: `ffmpeg -ss 3 -i in.mp4 -frames:v 1 output/thumb.jpg`.
- Fade in/out: `-vf "fade=t=in:d=0.5,fade=t=out:st=<dur-0.5>:d=0.5" -af "afade=t=in:d=0.5,afade=t=out:st=<dur-0.5>:d=0.5"`.
- Normalize loudness: `-af loudnorm=I=-14:TP=-1.5:LRA=11` (social), `I=-16` for podcasts.

Platform targets:
- TikTok / Reels / Shorts: 1080x1920, 30 fps, H.264, AAC 44.1 or 48 kHz, under 60 s for Shorts (up to 3 min now allowed), keep captions out of the bottom 20 percent.
- YouTube: keep source resolution and fps, `-crf 18`, `-movflags +faststart`.
- X: up to 1920x1200, 140 s, 512 MB. Slack/email: aim under 25 MB.
- Always add `-pix_fmt yuv420p` for compatibility (QuickTime, iPhone, web).

## Quality checklist

- Output plays in QuickTime (`open`) with sound in sync.
- Duration matches the plan; cuts land where intended (check a frame near each cut with `-ss`).
- Resolution, aspect and file size meet the platform.
- Text and faces not cropped off in vertical crops.
- Audio not clipping; loudness reasonable.
- Input file unchanged.

## Reply to the user

One to three sentences with the path and key facts, e.g. "Made a 9:16 version for TikTok, 42 seconds, 18 MB, at output/launch-vertical.mp4."

## Pitfalls

- `-c copy` with `-ss` cuts on keyframes and can start with a frozen frame; re-encode for exact cuts.
- Odd widths/heights fail with libx264; use `-2` in `scale` to keep them even.
- Forgetting `-pix_fmt yuv420p` makes files that will not play on some devices.
- iPhone HDR/HEVC clips look washed out when converted; add `-vf "zscale=t=linear,tonemap=hable,zscale=t=bt709,format=yuv420p"` if needed.
- Concat demuxer silently breaks with mismatched codecs.
- Uploading or posting anything without the user's yes.

Based on: popular ffmpeg skills (e.g. "ffmpeg-usage" recipe collections)
