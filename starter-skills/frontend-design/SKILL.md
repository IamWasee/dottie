---
name: frontend-design
description: Use when the user asks to build, design or restyle a web page, UI, component, dashboard or small web app and wants it to look polished and distinctive rather than generic.
---

# Frontend Design

## When to use

- The user wants a web interface: a page, a component, a dashboard, a tool, a prototype, or a small app.
- The user says "make it look good", "redesign this", "make a UI for", "build a web app that".
- Not for a full marketing site with pricing and FAQ: use `landing-page`.
- Not for a fixed-size image (poster, thumbnail, social card): use `poster-and-graphics`.
- If the user has a brand file (`brand.md`), read it first and follow it (see `brand-guidelines`).

## Steps

1. Pin down the job in one line: who uses it, what they do on it, what the one main action is.
2. Pick an aesthetic direction on purpose and write it at the top of the file as a comment, e.g. "editorial, warm paper, serif headlines" or "dense terminal, monospace, one acid accent". Avoid the default look: purple-to-blue gradient, centered card, Inter everywhere, emoji icons.
3. Choose the format:
   - Default: one self-contained `output/<name>/index.html` with inline CSS and JS. No build step.
   - If the user wants a real app with several views or state: Vite + vanilla JS or React in `output/<name>/` (`npm create vite@latest <name> -- --template react`), only if Node is installed (`node -v`).
4. Set design tokens first as CSS custom properties on `:root`: 1 background, 1 surface, 1 text, 1 muted text, 1 border, 1 accent, plus a dark-mode set under `@media (prefers-color-scheme: dark)`.
5. Typography: pair one display face with one text face from Google Fonts (e.g. Fraunces + Inter Tight, Space Grotesk + IBM Plex Sans, Instrument Serif + Geist). Use a type scale (e.g. 14, 16, 20, 28, 40, 56 px). Body line-height 1.5, headings 1.1 to 1.2, line length 60 to 75 characters.
6. Spacing: use a 4 or 8 px scale (4, 8, 12, 16, 24, 32, 48, 64, 96). Keep generous outer margins; group related items tightly and separate groups widely.
7. Layout: CSS grid and flexbox, mobile first, one breakpoint around 768 px and one around 1100 px. No horizontal scroll at 375 px width.
8. Motion: a few meaningful transitions (hover, enter, state change), 150 to 300 ms, `ease-out` for entering. Respect `@media (prefers-reduced-motion: reduce)`.
9. Build real content, not lorem ipsum. Use realistic labels, numbers and empty states.
10. Make every interactive element reachable by keyboard, with a visible `:focus-visible` style and `cursor: pointer`.
11. Preview with `open output/<name>/index.html` and take a screenshot to check it (see Tools).
12. Fix what looks off, then reply.

## Tools on a Mac

- Preview: `open output/<name>/index.html` (default browser).
- Screenshot without clicking: headless Chrome, if installed:
  `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars --window-size=1440,900 --screenshot=tmp/desktop.png file://$PWD/output/<name>/index.html`
  Repeat with `--window-size=390,844` for phone width.
- Fallback thumbnail: `qlmanage -t -s 1200 -o tmp output/<name>/index.html`.
- Local server for apps that fetch files: `python3 -m http.server 8000 -d output/<name>` then `open http://localhost:8000`.
- Icons: inline SVG from Lucide or Heroicons (copy the path), not icon fonts.
- Vite apps: `npm install`, `npm run build` (static files land in `dist/`).

## Quality checklist

- A clear visual hierarchy: you can tell the main action within two seconds.
- Contrast at least 4.5:1 for body text, 3:1 for large text and UI borders.
- Works at 390 px and 1440 px; no overflowing text or clipped buttons.
- Dark mode looks intentional, not inverted.
- No console errors (check with headless Chrome `--enable-logging=stderr --v=0` or open DevTools).
- Fonts load from one Google Fonts link with `display=swap`; fallbacks set.
- Images have `alt`, buttons have text or `aria-label`.
- Nothing points at files outside `output/<name>/`.

## Reply to the user

One to three plain sentences: what you built, the look you chose, and the path, e.g. "Built the habit tracker as one page with a warm editorial look. It's at output/habit-tracker/index.html and I opened it for you."

## Pitfalls

- Shipping the generic AI look (gradient hero, glassmorphism cards, three identical feature boxes). Commit to one idea.
- Too many fonts or accent colors. Two families, one accent.
- Hardcoding colors in components instead of the tokens, which breaks dark mode.
- Fixed pixel heights that clip text at phone width.
- Loading big frameworks from a CDN for a page that needs 40 lines of JS.
- Reporting "done" without looking at a screenshot.
- Publishing or deploying anywhere without the user's yes.

Based on: anthropics/skills "frontend-design"
