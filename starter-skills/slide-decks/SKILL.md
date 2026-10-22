---
name: slide-decks
description: Use when the user wants a presentation: "make slides", "build a deck", "turn this into a PowerPoint/Keynote", pitch decks, talks, or editing an existing .pptx or .key file.
---

# Slide Decks

## When to use

- Building a new deck as .pptx (opens in PowerPoint, Keynote and Google Slides).
- Building one in Keynote when the user asks for Keynote by name.
- Editing, reordering or pulling text out of an existing .pptx.
- Exporting a deck to PDF.
- Not for a written report: use `word-documents` or `doc-coauthoring`.

## Steps

1. Get the point of the talk in one sentence, the audience and the length (minutes or slide count). If the user gave none, assume 10 minutes and 8 to 12 slides.
2. Write the outline in `tmp/outline.md` first: one line per slide stating the single idea it carries, as a full sentence ("Churn fell 20% after onboarding changes"), not a topic ("Churn").
3. Shape it: title slide, the problem or question, 3 to 7 body slides, a summary or ask, a closing slide. One idea per slide; at most 5 bullets of at most 8 words each.
4. Put detail in speaker notes, not on the slide. Every body slide gets 2 to 5 sentences of notes the presenter could read.
5. Build with python-pptx (below). Use the built-in layouts so the deck stays editable: 0 title, 1 title and content, 5 title only, 6 blank.
6. Add visuals where they carry the idea: a chart from real numbers, an image the user gave, or a big single number. No decorative clip art.
7. Save `output/<topic>-deck.pptx`. Render a check: `qlmanage -t -s 1200 -o tmp output/<topic>-deck.pptx` for slide one, and export to PDF (below) to review every slide.

## Tools on a Mac

- `python3 -m pip install --user python-pptx`

```python
from pptx import Presentation
from pptx.util import Inches, Pt
deck = Presentation()
deck.slide_width, deck.slide_height = Inches(13.333), Inches(7.5)   # 16:9
slide = deck.slides.add_slide(deck.slide_layouts[1])
slide.shapes.title.text = "Churn fell 20% after the new onboarding"
body = slide.placeholders[1].text_frame
body.text = "Trial-to-paid up from 31% to 38%"
body.add_paragraph().text = "Biggest gain: teams of 5 to 20"
slide.notes_slide.notes_text_frame.text = "Start with the number, then explain why."
deck.save("output/churn-deck.pptx")
```

- Charts: `from pptx.chart.data import CategoryChartData` and `slide.shapes.add_chart(XL_CHART_TYPE.COLUMN_CLUSTERED, x, y, cx, cy, chart_data)`.
- Images: `slide.shapes.add_picture("photo.png", Inches(1), Inches(1.5), height=Inches(5))`. Resize big photos first: `sips -Z 1920 photo.jpg --out tmp/photo.jpg`.
- Read a deck: loop `deck.slides`, then `shape.has_text_frame` and `shape.text_frame.text`; notes in `slide.notes_slide.notes_text_frame.text`.
- Keynote export to PDF (Keynote installed):

```bash
osascript -e 'tell application "Keynote"
  set theDoc to open POSIX file "/full/path/output/deck.pptx"
  export theDoc to POSIX file "/full/path/output/deck.pdf" as PDF
  close theDoc saving no
end tell'
```

- Without Keynote: `brew install --cask libreoffice` then `soffice --headless --convert-to pdf --outdir output output/deck.pptx` (large install; ask first).
- Check every slide: `pdftoppm -png -r 60 output/deck.pdf tmp/slide` (from `brew install poppler`) and look at the images.

## Quality checklist

- Each slide title is a sentence that states its point; reading only the titles tells the story.
- No slide has more than 5 bullets or text below 18 pt.
- Nothing overflows its box (check the rendered PDF or PNGs).
- Every body slide has speaker notes.
- Numbers on slides match the source; chart axes are labeled.
- 16:9 unless the user asked for 4:3.

## Reply to the user

One or two sentences: slide count, the storyline in a phrase, the path. For example: "Made a 9-slide deck on the Q3 churn results with speaker notes; it's at output/churn-deck.pptx, plus a PDF copy."

## Pitfalls

- python-pptx does not auto-shrink text; long bullets spill off the slide silently. Keep bullets short or lower the font size yourself.
- Default python-pptx decks are 4:3. Set the width and height for 16:9 before adding slides.
- `slide_layouts` indexes differ in custom templates; print `[layout.name for layout in deck.slide_layouts]` first.
- Keynote scripting needs Automation permission and opens the app on screen; use it only when asked.
- Do not fill slides with paragraphs copied from the source document.
- Fonts not on the Mac fall back silently; stick to system fonts like Helvetica Neue or the template's.

Based on: anthropics/skills "pptx"
