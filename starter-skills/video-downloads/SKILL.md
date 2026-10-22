---
name: video-downloads
description: Use when the user wants a video or its audio saved from a link they have the right to keep: "download my YouTube video", "save this talk as mp3", "get the subtitles", Creative Commons or public domain clips.
---

# Video Downloads

## When to use

- Downloading the user's own uploads, Creative Commons or public domain videos, or clips the site lets everyone download.
- Getting audio only, a lower resolution, or subtitles from such a video.
- Not for DRM-protected or paid content: Netflix, Disney+, Prime Video, Spotify, Apple Music, paid courses, members-only or paywalled videos. Say no plainly and suggest the service's own offline download feature.
- Not for converting or editing files already on the Mac: use ffmpeg directly.

## Steps

1. Check the rights. Look at the page: is it the user's channel, marked Creative Commons, public domain (archive.org, government sources), or a site with a download button? If unclear, ask the user whether it is theirs or licensed for reuse. If it's a paid or DRM service, stop.
2. Check tools: `command -v yt-dlp ffmpeg`. Install missing ones with `brew install yt-dlp ffmpeg` (see `homebrew-cli-tools`).
3. Look before downloading: `yt-dlp -F URL` lists formats; `yt-dlp --print "%(title)s | %(duration_string)s | %(license)s" URL` shows title, length and the license if the site reports it.
4. Download into `output/`, named by title:
   - Best quality as MP4: `yt-dlp -f "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b" --merge-output-format mp4 -o "output/%(title)s.%(ext)s" URL`
   - Capped at 1080p: `-f "bv*[height<=1080]+ba/b[height<=1080]"`
   - Audio only as MP3: `yt-dlp -x --audio-format mp3 --audio-quality 0 -o "output/%(title)s.%(ext)s" URL`
   - Subtitles only: `yt-dlp --skip-download --write-subs --write-auto-subs --sub-langs "en.*" --convert-subs srt -o "output/%(title)s" URL`
   - A section: `--download-sections "*00:01:30-00:03:00"`
5. Playlists: confirm the count first (`yt-dlp --flat-playlist --print title URL | wc -l`) and ask before pulling more than about 20 videos. Add `--no-playlist` when the user meant one video from a playlist link.
6. Verify the file: `ffprobe -v error -show_entries format=duration,size -of default=nw=1 output/file.mp4`, and that it plays (`qlmanage -p` previews it).

## Tools on a Mac

- `yt-dlp` (Homebrew): `-F`, `-f`, `-x`, `--audio-format`, `--write-subs`, `--embed-subs`, `--embed-thumbnail`, `--restrict-filenames`, `--no-playlist`, `-o` templates.
- `ffmpeg`/`ffprobe` (Homebrew), needed for merging video and audio and for MP3.
- `afconvert -f m4af -d aac in.wav out.m4a` (built in) for simple audio conversions without ffmpeg.
- `qlmanage -p file` to preview; `open output/` to show the folder.
- `yt-dlp --list-subs URL` to see which subtitle languages exist before asking for them.
- `yt-dlp --embed-subs --embed-thumbnail --add-metadata` to keep subtitles, cover art and title inside the MP4.
- `ffmpeg -i in.mp4 -vn -c:a copy output/audio.m4a` pulls audio from a file already downloaded without re-encoding.
- `brew upgrade yt-dlp` when sites change and downloads start failing (only that formula).

- `yt-dlp --download-archive tmp/archive.txt` skips videos already fetched when the user asks again for the same channel or playlist.
- `yt-dlp --print filename -o "output/%(title)s.%(ext)s" URL` shows the final file name before downloading.

## Quality checklist

- Rights checked; nothing from a DRM, paid or members-only source.
- File plays, has sound, and the duration matches the page.
- Saved in `output/` with a readable name; `--restrict-filenames` if the title has odd characters.
- For Creative Commons, note the license and creator in `output/<title>-credits.txt` so the user can attribute it.
- No cookies, logins or browser sessions used to reach content the user couldn't otherwise download.

## Reply to the user

One sentence with what and where, for example "I saved the talk as an MP3 (42 minutes) in output/." If you refused, say why in one sentence and name the legitimate route (the app's offline download).

## Pitfalls

- "HTTP Error 403" or "Requested format is not available" usually means an outdated yt-dlp; upgrade it once and retry.
- Without ffmpeg, yt-dlp downloads separate video and audio files instead of one MP4.
- `--cookies-from-browser` exists but is a way around access controls; don't use it for content the user doesn't own or isn't allowed to save.
- Auto-generated subtitles can be poor; say they're automatic.
- Big files: a 1-hour 4K video can be several GB. Check `df -h ~` first and cap the height if space is tight.
- Long titles with slashes or emoji break paths; use `--restrict-filenames` or `-o "output/%(id)s.%(ext)s"`.
- Uploading or re-sharing the file anywhere waits for the user's yes, and the license still applies.

Based on: written for Dottie
