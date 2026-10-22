---
name: word-documents
description: Use when the user wants a Word file (.docx) made, edited, filled in or converted: "make this a Word doc", "fix the formatting in report.docx", "turn my notes into a docx".
---

# Word Documents

## When to use

- Creating a new .docx from notes, Markdown or an outline.
- Editing an existing .docx: replacing text, adding sections or tables, fixing headings, filling a template.
- Converting between .docx and .md, .html, .rtf, .txt or .pdf.
- Not for long writing done with the user over several rounds: use `doc-coauthoring` for the writing, then this skill for the file.
- Not for PDFs as the main input or output: use `pdf-tools`.

## Steps

1. Find the source. Copy any file the user names into `tmp/` and work on the copy; never edit the original in place.
2. Read before you write. Dump the text with `textutil -convert txt -stdout file.docx` or `pandoc file.docx -t markdown`. For styles and structure, list paragraphs with python-docx (see below).
3. Pick the route:
   - New document from plain content: write Markdown in `tmp/draft.md`, then `pandoc tmp/draft.md -o output/name.docx`. Add `--reference-doc=template.docx` when the user has a house style.
   - Small edits that must keep the original look: python-docx, changing text inside existing runs so fonts and styles survive.
   - Template filling: put placeholders like `{{client_name}}` in the template and replace them run by run.
4. Use real styles, not manual formatting: `Heading 1`, `Heading 2`, `List Bullet`, `Title`. That keeps the navigation pane and table of contents working.
5. Save to `output/` with a clear name, for example `output/project-brief-v2.docx`. Never overwrite the user's file unless they asked.
6. Check the result: convert back to text and read it, and render a preview with `qlmanage -t -s 1200 -o tmp output/name.docx` to see the first page.

## Tools on a Mac

- `textutil -convert docx notes.rtf -output output/notes.docx` (built in; handles txt, rtf, html, doc, docx, odt).
- `textutil -convert txt -stdout report.docx` to read text quickly.
- `textutil -convert html report.docx -output tmp/report.html` then `cupsfilter tmp/report.html > output/report.pdf` for a quick PDF.
- `qlmanage -t -s 1200 -o tmp file.docx` for a PNG thumbnail of page one.
- `mdls -name kMDItemNumberOfPages file.docx` sometimes has a page count.
- `brew install pandoc` for Markdown to Word with headings, lists, tables and footnotes:
  `pandoc in.md -o out.docx --toc --reference-doc=ref.docx`.
- `python3 -m pip install --user python-docx` for editing:

```python
from docx import Document
document = Document("tmp/report.docx")
for paragraph in document.paragraphs:
    print(paragraph.style.name, "|", paragraph.text)
document.add_heading("Next steps", level=2)
document.add_paragraph("Ship the beta on Friday.", style="List Bullet")
document.save("output/report-edited.docx")
```

- Replacing text without losing formatting: loop `paragraph.runs` and change `run.text`. Setting `paragraph.text` wipes the runs and their formatting.
- Tables: `document.tables[0].cell(row, column).text`; add with `document.add_table(rows=1, cols=3, style="Table Grid")`.

## Quality checklist

- Opens without errors: `python3 -c "import docx; docx.Document('output/x.docx')"`.
- Headings use heading styles; the outline reads correctly in `pandoc -t markdown`.
- No leftover placeholders: `textutil -convert txt -stdout output/x.docx | grep -n '{{'` finds nothing.
- Fonts, header, footer and page size match the original when editing.
- Tables have a header row and no empty columns.
- File name says what it is; the original file is untouched.

## Reply to the user

One or two sentences: what you made or changed and where it is, for example "I made the project brief as a Word file with four sections; it's in output/project-brief.docx." Mention anything you could not keep, like tracked changes.

## Pitfalls

- Tracked changes and comments: python-docx cannot accept, reject or create tracked changes, and pandoc drops them unless you pass `--track-changes=all` when reading. If the user's file has revisions, say so and ask whether to keep, accept or ignore them before editing.
- Editing `paragraph.text` destroys bold, italics and links in that paragraph. Edit runs.
- Placeholders split across runs (Word often breaks `{{name}}` into pieces) will not match. Join the runs' text, replace, and write it back into the first run.
- `.doc` (old binary format) is not readable by python-docx. Convert first: `textutil -convert docx old.doc -output tmp/old.docx`.
- textutil conversions lose complex layout (columns, text boxes). Use it for reading and simple files only.
- Pandoc ignores the styles of a docx you did not pass as `--reference-doc`.
- Do not email or upload the file; saving it in `output/` is the job.

Based on: anthropics/skills "docx"
