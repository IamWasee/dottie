---
name: brand-guidelines
description: Use when the user wants to capture a brand (colors, fonts, logo rules, tone of voice) into a brand file, or apply their brand to a doc, deck, site, post or graphic so it looks and sounds on-brand.
---

# Brand Guidelines

## When to use

- "Make a brand guide", "pull the colors and fonts from my site", "write down our brand", "make this match our brand".
- Any design or writing task where the user has a brand: check for `brand.md` in the working folder, `output/`, or the skills library first.
- Not for designing a new web page or image from scratch: do the work with `frontend-design`, `landing-page` or `poster-and-graphics`, using this skill's `brand.md` as the source of truth.

## Steps

### Capture a brand

1. Collect sources: the user's website URL, logo files, existing decks or docs, screenshots. Work only from what they give or what is public.
2. Colors: for a site, fetch the HTML and CSS (`curl -sL <url> -o tmp/site.html`, then the linked stylesheets) and pull hex values and CSS variables (`grep -oE '#[0-9a-fA-F]{6}\b' tmp/*.css | sort | uniq -c | sort -rn | head -20`). For a logo or image, sample dominant colors (see Tools). Pick 1 primary, 1 or 2 secondary, 2 or 3 neutrals, plus success/warning/error if used.
3. Fonts: read `font-family` and Google Fonts links in the CSS. Note heading font, body font, weights, and a free fallback for each.
4. Logo: list each file, its versions (full, mark only, light, dark), minimum size, clear space (e.g. the height of the mark's letter), and don'ts (no stretching, recoloring, shadows, busy backgrounds).
5. Voice: read 3 to 5 pieces of their copy. Describe the tone in 3 adjectives, each with a "this, not that" pair, plus words they use and words they avoid. Add 2 short example lines.
6. Write `output/brand/brand.md` with sections: Name and one-line description, Colors (table: name, hex, RGB, use), Typography (font, weights, sizes for H1, H2, body, caption), Logo (files and rules), Imagery (photo style, illustration style), Voice and tone, Do and don't, Ready-made tokens (a CSS `:root` block).
7. Copy logo files to `output/brand/assets/` and make a one-page preview `output/brand/brand-preview.html` showing swatches, type samples and the logo on light and dark.
8. Check every color pair you recommend for text against WCAG contrast and note it in the table.

### Apply a brand

1. Read `brand.md` fully before starting.
2. Use only its colors (via tokens), its fonts (or the listed fallbacks), its logo files untouched, and its voice.
3. For Office files, set theme colors and fonts in the template, not per text box (see the docx/pptx skills if present).
4. Before finishing, compare the result against the "Do and don't" list.

## Tools on a Mac

- Fetch a site: `curl -sL https://example.com -o tmp/site.html`.
- Dominant colors from an image: `magick logo.png -resize 200x200 -colors 6 -unique-colors txt:- ` (`brew install imagemagick`). Python fallback: `python3 -m pip install --user pillow`, then `Image.quantize(colors=6)`.
- Image info: `sips -g pixelWidth -g pixelHeight -g space logo.png`; `mdls logo.svg`.
- Fonts installed: `system_profiler SPFontsDataType | grep -i "Family:" | sort -u | head -50`.
- Contrast ratio: compute in `python3` with the WCAG relative luminance formula.
- SVG to PNG preview: `qlmanage -t -s 800 -o tmp logo.svg`.
- Preview: `open output/brand/brand-preview.html`.

## Quality checklist

- Every hex in `brand.md` came from a real source (site, file, user), not guessed.
- Text color pairs listed as allowed pass 4.5:1 contrast.
- Fonts named with a free fallback that is actually available.
- Logo rules include clear space, minimum size and at least 3 don'ts.
- Voice section has concrete examples, not only adjectives.
- The CSS tokens block matches the color table exactly.
- When applying: no off-brand colors or fonts slipped in.

## Reply to the user

One to three sentences: what you captured or applied and where, e.g. "I wrote your brand guide to output/brand/brand.md with 6 colors, 2 fonts and voice notes. A visual preview is in output/brand/brand-preview.html."

## Pitfalls

- Picking up random colors from third-party widgets, ads or cookie banners on the site.
- Treating a paid font as free; always give a free fallback.
- Recoloring or redrawing the logo instead of using the supplied files.
- Voice rules so vague ("friendly, professional") that they guide nothing.
- Downloading assets from sites the user doesn't own for anything beyond reference.

Based on: anthropics/skills "brand-guidelines"
