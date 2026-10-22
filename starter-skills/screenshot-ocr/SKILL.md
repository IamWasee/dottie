---
name: screenshot-ocr
description: Use when text must be read out of an image, screenshot or scanned PDF: "copy the text from this screenshot", "OCR this scan", "get the table out of this picture", "what does this photo say".
---

# Screenshot OCR

## When to use

- Pulling text from screenshots, photos of documents, receipts, slides or scanned PDFs.
- Rebuilding a table seen in an image as CSV.
- Putting the extracted text on the clipboard.
- Not for PDFs that already have a text layer: try `pdftotext` first (see the `pdf-tools` skill). Only OCR when that returns nothing.

## Steps

1. Find the input. Screenshots are usually on the Desktop: `ls -t ~/Desktop/*.png | head -5`. Copy the file into `tmp/`.
2. If it's a PDF, check for real text first: `pdftotext -layout tmp/in.pdf - | head`. Empty output means it's a scan; turn pages into images: `pdftoppm -r 300 -png tmp/in.pdf tmp/page` (poppler) or, built in, `sips -s format png tmp/in.pdf --out tmp/page.png` (first page only).
3. Prepare small or blurry images: upscale with `sips -Z 3000 tmp/in.png` when the text is tiny. Leave clear images alone.
4. OCR with macOS Vision (best quality, no install) using the Swift script below. Fall back to tesseract if Swift is unavailable.
5. Read the result and fix obvious OCR errors only when certain (0/O, 1/l, broken hyphenation). Never guess numbers, names or amounts; mark unsure parts with `[?]`.
6. Tables: Vision returns lines with bounding boxes. Group words into rows by their y position and into columns by x gaps, then write `output/<name>.csv`. Check the column count is the same on every row.
7. Save the text to `output/<name>.txt` (or `.md`/`.csv`) and, if the user asked, copy it: `pbcopy < output/name.txt`.

## Tools on a Mac

- Vision OCR, saved as `tmp/ocr.swift` and run with `swift tmp/ocr.swift tmp/in.png > tmp/out.txt`:

```swift
import Vision
import AppKit
let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = NSImage(contentsOf: imageURL),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
try VNImageRequestHandler(cgImage: cgImage).perform([request])
for observation in request.results ?? [] {
    guard let best = observation.topCandidates(1).first else { continue }
    let box = observation.boundingBox
    print(String(format: "%.3f\t%.3f\t%@", box.minY, box.minX, best.string))
}
```

  Output is `y<TAB>x<TAB>text`, y measured from the bottom. Sort by y descending for reading order; strip the first two columns for plain text: `sort -t$'\t' -k1,1nr -k2,2n tmp/out.txt | cut -f3-`.
- Other languages: set `request.recognitionLanguages = ["de-DE", "en-US"]`.
- `swift` needs the Xcode command line tools. If missing (`xcode-select -p` fails), use tesseract.
- `brew install tesseract` then `tesseract tmp/in.png stdout` or `tesseract tmp/in.png tmp/out --psm 6` (block of text); add `-l deu` with `brew install tesseract-lang` for other languages; `tesseract tmp/in.png tmp/out tsv` gives word positions for tables.
- `brew install poppler` for `pdftotext` and `pdftoppm`.
- `sips -g pixelWidth -g pixelHeight file.png` for size; `sips -Z 3000` to upscale; `sips -s format png in.heic --out tmp/in.png` for iPhone photos.
- `screencapture -x tmp/screen.png` captures the screen if the user says "read what's on my screen" (needs Screen Recording permission).
- `pbcopy < file` puts text on the clipboard.

## Quality checklist

- Reading order is right (top to bottom, columns not interleaved).
- Numbers, dates, amounts and names match the image when spot-checked.
- Unsure characters are marked, not invented.
- Tables have the same number of columns on every row and a header row.
- The original file is untouched; output is in `output/`.

## Reply to the user

One or two sentences, for example "I pulled the text from the receipt; it's in output/receipt.txt and on your clipboard." If a part was unreadable, say which part. For short text (a line or two), you can include it in the reply.

## Pitfalls

- Low-resolution screenshots of small fonts: upscale before OCR, never after.
- Multi-column layouts read across columns; split by x position before joining lines.
- Handwriting is unreliable with tesseract; Vision does better but still check.
- HEIC photos must be converted first for tesseract.
- `pdftotext` on a scan returns blank pages, not an error. Check for empty output.
- Don't paste sensitive text (IDs, account numbers) into the reply to be read aloud; point to the file.

Based on: written for Dottie
