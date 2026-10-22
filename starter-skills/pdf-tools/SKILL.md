---
name: pdf-tools
description: Use when the task involves a PDF: read or summarize it, pull out text or tables, merge, split, rotate, fill a form, compress, or make a new PDF from a page, doc or notes.
---

# PDF Tools

## When to use

- Reading a PDF to answer questions or summarize it.
- Extracting text, tables or images.
- Merging, splitting, reordering, rotating, compressing or password-removing (with a password the user gives for this one file) PDFs.
- Filling a PDF form.
- Making a PDF from HTML, Markdown, a Word file or images.
- Not for editing the content of a Word file: use `word-documents`, then export.

## Steps

1. Copy the input to `tmp/` and work on copies. Never change the user's original.
2. Inspect first: `pdfinfo tmp/in.pdf` (pages, size, encrypted?) and `pdffonts tmp/in.pdf` (no fonts listed usually means a scanned image PDF).
3. Do the task with the matching recipe below.
4. Write results to `output/` with a descriptive name, for example `output/contract-signed-pages-1-3.pdf`.
5. Verify: `pdfinfo` on the output (page count right?), and `qlmanage -t -s 1000 -o tmp output/x.pdf` to look at page one.

## Tools on a Mac

Built in:
- `mdls -name kMDItemNumberOfPages in.pdf` for a page count.
- `textutil -convert html notes.txt -output tmp/notes.html` then `cupsfilter tmp/notes.html > output/notes.pdf` to make a simple PDF.
- `sips -s format pdf photo.jpg --out tmp/photo.pdf` for one image to PDF.
- `qlmanage -t -s 1000 -o tmp in.pdf` for a thumbnail.
- `open -a Preview output/x.pdf` only if the user asks to see it.

Homebrew (`brew install poppler qpdf`):
- Text: `pdftotext -layout in.pdf tmp/in.txt` (keeps columns; add `-f 3 -l 5` for pages 3 to 5).
- Images: `pdfimages -png in.pdf tmp/img`.
- Pages to PNG: `pdftoppm -png -r 150 -f 1 -l 1 in.pdf tmp/page`.
- Merge: `qpdf --empty --pages a.pdf b.pdf -- output/merged.pdf`.
- Split pages 1-3: `qpdf in.pdf --pages . 1-3 -- output/part1.pdf`; every page: `qpdf --split-pages in.pdf tmp/page-%d.pdf`.
- Rotate page 2 by 90: `qpdf in.pdf output/rotated.pdf --rotate=+90:2`.
- Compress and fix: `qpdf --linearize --object-streams=generate in.pdf output/smaller.pdf`.
- Remove a known password: `qpdf --password='...' --decrypt in.pdf output/open.pdf` (the user types it for this run; never save it).

Python (`python3 -m pip install --user pypdf pdfplumber`):

```python
import pdfplumber
with pdfplumber.open("tmp/in.pdf") as pdf:
    for page in pdf.pages:
        for table in page.extract_tables():
            print(table)
```

Form filling with pypdf:

```python
from pypdf import PdfReader, PdfWriter
reader = PdfReader("tmp/form.pdf")
print(reader.get_fields().keys())   # learn the real field names first
writer = PdfWriter(clone_from=reader)
writer.update_page_form_field_values(writer.pages[0], {"Name": "Ada Lovelace"}, auto_regenerate=False)
writer.set_need_appearances_writer(True)
writer.write("output/form-filled.pdf")
```

- Tables to CSV: write `extract_tables()` rows with the `csv` module to `output/tables.csv`.
- Markdown to PDF: `pandoc in.md -o tmp/in.html --standalone` then `cupsfilter tmp/in.html > output/in.pdf`.
- Scanned PDFs (no text): `brew install ocrmypdf` then `ocrmypdf in.pdf output/searchable.pdf`.

## Quality checklist

- Output page count matches what you expected.
- Extracted text is not empty or garbled; if it is, the PDF is scanned, so OCR it.
- Filled forms show the values when rendered (check the thumbnail), not only in field data.
- Rotations and page order look right in the preview.
- Nothing was printed, uploaded or shared.

## Reply to the user

One to three sentences with the result and the path, for example "Merged the three invoices into one 7-page PDF at output/invoices-march.pdf." For a summary, give the two or three key points and say the full text is in `output/`.

## Pitfalls

- `pdftotext` without `-layout` scrambles tables and multi-column pages.
- Form field names in the file rarely match the labels on the page; read them with `get_fields()` before filling.
- Flattened or XFA forms cannot be filled with pypdf; say so and offer to overlay text instead.
- `cupsfilter` prints a harmless "using default" warning; check the output size, not the warning.
- Large scanned PDFs can be hundreds of MB after `pdftoppm`; keep renders in `tmp/` and delete them when done.
- Never guess or brute-force passwords on encrypted PDFs.

Based on: anthropics/skills "pdf"
