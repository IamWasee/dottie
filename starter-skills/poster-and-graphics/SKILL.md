---
name: poster-and-graphics
description: Use when the user wants a poster, flyer, social media image, YouTube thumbnail, banner, cover, quote card or other static graphic made as a PNG or PDF.
---

# Poster and Graphics

## When to use

- "Make a poster for", "an Instagram post", "a YouTube thumbnail", "a banner for LinkedIn", "a flyer", "an event graphic", "a cover image".
- The output is a fixed-size picture, built as SVG or HTML and rendered to PNG (and PDF for print).
- Not for editing an existing photo (resize, crop, background removal): use `image-editing`.
- Not for a scrolling web page: use `frontend-design` or `landing-page`.
- Not for animation: use `gif-maker` or `video-editing-ffmpeg`.

## Steps

1. Pick the exact canvas size:
   - Instagram post 1080x1350 (4:5) or 1080x1080; story/reel cover 1080x1920.
   - YouTube thumbnail 1280x720 (under 2 MB).
   - X/Twitter 1600x900; LinkedIn post 1200x1200, banner 1584x396.
   - Open Graph 1200x630. Facebook cover 1640x624.
   - Print poster: A3 is 297x420 mm; render at 300 dpi (3508x4961 px) or export PDF; 18x24 in is 5400x7200 px.
2. Decide the one message and the reading order: headline, then image, then detail, then call to action. If it has more than 3 levels, cut.
3. Compose:
   - Use a grid (e.g. 12 columns, margins 5 to 8 percent of width). Align everything to it.
   - One focal point, large. Headline at least 8 percent of canvas height for thumbnails, and readable at 20 percent scale.
   - 2 typefaces max, 1 accent color plus neutrals (from `brand.md` if present).
   - Leave real empty space; keep text out of the outer 5 percent (safe area) and out of platform overlays (bottom 20 percent of stories, bottom-right of YouTube where the timestamp sits).
   - Contrast: put text on flat color or a darkened area of the photo, never straight over a busy region.
4. Build it as `tmp/<name>.html` (a fixed-size `body` with `margin:0`, exact `width` and `height` in px) or `tmp/<name>.svg` with a matching `viewBox`. Embed fonts via Google Fonts or `@font-face` to a local file.
5. Render to PNG at exact size (see Tools). Check the pixel size with `sips`.
6. Look at the PNG, also shrunk to 25 percent, and fix legibility and balance.
7. For several sizes, keep one source and change only the canvas and layout per size. Name files `output/<name>-<width>x<height>.png`.
8. For print, also save a PDF and note bleed (3 mm) if the user is printing professionally.

## Tools on a Mac

- HTML to PNG at an exact size (Chrome):
  `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --window-size=1280,720 --screenshot=$PWD/output/thumb-1280x720.png file://$PWD/tmp/thumb.html`
  Use `--force-device-scale-factor=2` for a 2x crisp version, then downscale with `sips`.
- HTML to PDF: same Chrome with `--print-to-pdf=$PWD/output/poster.pdf --no-pdf-header-footer` and an `@page { size: 297mm 420mm; margin: 0 }` rule.
- SVG to PNG: `rsvg-convert -w 1080 -h 1350 in.svg -o out.png` (`brew install librsvg`), or `magick -density 300 in.svg out.png`. Quick preview: `qlmanage -t -s 1080 -o tmp in.svg` (thumbnail quality, not for final).
- Check size: `sips -g pixelWidth -g pixelHeight output/thumb-1280x720.png`.
- Shrink to check legibility: `sips -Z 320 output/thumb-1280x720.png --out tmp/small.png`.
- Compress PNG: `pngquant --quality 70-90 --output out.png in.png` (`brew install pngquant`); JPEG with `sips -s format jpeg -s formatOptions 85`.
- Open to look: `open output/thumb-1280x720.png`.

## Quality checklist

- Exact pixel size for the target platform; file size within its limit.
- Headline readable at thumbnail size (25 percent scale).
- Nothing important in the safe-area margins or overlay zones.
- Text contrast at least 4.5:1, or large text 3:1.
- Fonts actually rendered (no fallback serif where you meant a custom font).
- No spelling mistakes; dates, times, prices and URLs checked against the user's message.
- Only images the user supplied, made, or that are clearly free to use.

## Reply to the user

One to three sentences with the file paths, e.g. "Made the event poster at A3 as output/jazz-night-poster.pdf and a 1080x1350 Instagram version as output/jazz-night-1080x1350.png."

## Pitfalls

- Rendering before web fonts load: add a short delay (`--virtual-time-budget=3000`) or use local font files.
- Retina screenshots doubling the size; set `--force-device-scale-factor`.
- Cramming every detail onto the poster. One message.
- Thin light fonts that vanish when compressed.
- Using logos, characters or photos the user has no rights to.
- Posting the graphic anywhere without the user's yes.

Based on: anthropics/skills "canvas-design"
