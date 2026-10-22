---
name: image-editing
description: Use when the user wants to resize, crop, convert (HEIC, PNG, JPG, WebP), compress, rotate, add borders or watermarks, remove a background, or batch-process a folder of images.
---

# Image Editing

## When to use

- "Resize these photos", "convert HEIC to JPG", "make this smaller for email", "crop to square", "remove the background", "turn these into WebP", "do this to the whole folder".
- Not for making a new graphic or poster from scratch: use `poster-and-graphics`.
- Not for animated output: use `gif-maker`.

## Steps

1. Find the inputs. Never edit originals in place: copy or write results to `output/` (or `output/<batch-name>/` for many files).
2. Inspect first: `sips -g pixelWidth -g pixelHeight -g format -g dpiWidth file`, and `ls -lh` for size. For a folder, count files and types.
3. Pick the tool: `sips` for simple resize, rotate, convert and crop (always present); `magick` for anything more (exact crops, padding, watermarks, quality control, sharpening); `cwebp` for WebP; `rembg` only for background removal.
4. Do one file first, show or check the result, then run the batch.
5. For batches, loop in the shell with quoted paths: `for f in in/*.HEIC; do sips -s format jpeg "$f" --out "output/$(basename "${f%.*}").jpg"; done`.
6. Verify outputs: dimensions, format, file size, count matches input count.
7. Keep metadata decisions explicit: strip location (EXIF GPS) for anything to be shared publicly with `magick in.jpg -strip out.jpg`; keep it for personal archives unless asked.

## Tools on a Mac

Built in (`sips`):
- Resize longest side to 1600 px: `sips -Z 1600 in.jpg --out output/in.jpg`
- Exact size (may distort): `sips -z 1080 1920 in.png --out out.png` (height first, then width).
- Convert: `sips -s format jpeg -s formatOptions 82 in.heic --out out.jpg` (formats: jpeg, png, heic, tiff, gif, pdf, bmp).
- Rotate / flip: `sips -r 90 in.jpg --out out.jpg`; `sips -f horizontal in.jpg --out out.jpg`.
- Center crop: `sips -c 1080 1080 in.jpg --out out.jpg` (height, width).
- Pad to canvas: `sips -p 1080 1080 --padColor FFFFFF in.png --out out.png`.
- Quick view: `qlmanage -p out.jpg` or `open out.jpg`.

ImageMagick (`brew install imagemagick`, command `magick`):
- Fill-crop to exact size: `magick in.jpg -resize 1080x1080^ -gravity center -extent 1080x1080 out.jpg`
- Crop region: `magick in.png -crop 800x600+120+40 +repage out.png`
- Compress JPEG: `magick in.jpg -sampling-factor 4:2:0 -strip -quality 80 -interlace JPEG out.jpg`
- Watermark text: `magick in.jpg -gravity southeast -fill "rgba(255,255,255,0.7)" -pointsize 36 -annotate +24+24 "(c) Name" out.jpg`
- Border: `magick in.jpg -bordercolor white -border 40 out.jpg`
- Batch to a folder: `magick mogrify -path output/small -resize 1200x1200\> -quality 82 *.jpg` (the `\>` means only shrink).
- Contact sheet: `magick montage *.jpg -tile 4x -geometry 300x300+8+8 output/sheet.jpg`

WebP and PNG size:
- `cwebp -q 80 in.png -o out.webp` (`brew install webp`); back with `dwebp in.webp -o out.png`.
- `pngquant --quality 65-85 --output out.png in.png` (`brew install pngquant`); lossless `oxipng -o 3 in.png` (`brew install oxipng`).

Background removal (optional, downloads a model on first run, about 170 MB):
- `python3 -m pip install --user "rembg[cli]"` then `rembg i in.jpg output/in-cutout.png`; batch `rembg p in/ output/cutouts/`.
- Output must be PNG or WebP to keep transparency.

## Quality checklist

- Originals untouched; results in `output/`.
- Output count equals input count; no zero-byte files.
- Dimensions and format are what the user asked for (`sips -g pixelWidth -g pixelHeight`).
- Faces and subjects not cut off by crops; aspect ratio not distorted unless asked.
- Compressed files are visibly fine at 100 percent zoom (no banding or blocky skies).
- Transparent cutouts saved as PNG/WebP with clean edges (check on a dark and light background).
- Sizes meet any stated limit (e.g. under 1 MB for a form upload).

## Reply to the user

One to three sentences: what changed, how many files, where, and a size note, e.g. "Converted 42 HEIC photos to JPG at 2000 px wide in output/trip-jpg/, about 600 KB each."

## Pitfalls

- `sips -z` and `-c` take height before width.
- `mogrify` without `-path` overwrites the originals.
- Saving a cutout as JPEG kills the transparency.
- Upscaling small images and calling them high resolution.
- Unquoted paths breaking on spaces in file names.
- HEIC from iPhone may carry rotation in EXIF; `magick -auto-orient` fixes it.
- Deleting originals; never do that without the user's yes.

Based on: written for Dottie
