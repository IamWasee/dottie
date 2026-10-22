---
name: landing-page
description: Use when the user wants a landing page, product page, one-page site or marketing site with hero, features, pricing, testimonials, FAQ and a call to action, as static files ready to deploy.
---

# Landing Page

## When to use

- "Make a landing page for my app", "a one-page site for my product", "a waitlist page", "a sales page".
- The result is a single scrolling marketing page that sells one thing.
- Not for an app UI, dashboard or tool: use `frontend-design`.
- Not for a single image or ad: use `poster-and-graphics`.
- If a `brand.md` exists in the folder or the skills library, follow it (see `brand-guidelines`).

## Steps

1. Gather the facts from the user's message and any files or URL they gave: product name, what it does, who it is for, the one action you want (sign up, buy, download, join waitlist), price, real quotes or numbers. Never invent testimonials, logos, user counts or reviews; use clearly marked placeholders like `[Customer quote]` instead.
2. Write the copy first in `tmp/copy.md`:
   - Hero: headline under 10 words that states the outcome, a subhead of one sentence on how, one primary button, one secondary link.
   - Value props: 3 or 4 benefits, each a short title plus one sentence, written as what the user gets.
   - How it works: 3 numbered steps.
   - Social proof: quotes, logos or numbers (real or placeholders).
   - Pricing: 1 to 3 tiers, the recommended one marked; what is included as bullets.
   - FAQ: 5 to 8 real objections (price, privacy, cancel, platforms, support).
   - Final CTA: restate the outcome and repeat the button.
   - Footer: name, contact, privacy and terms links.
3. Build `output/<slug>/index.html` with inline or one `styles.css`. Semantic HTML: `header`, `main`, `section` with `id`s, `footer`. FAQ with `<details><summary>`.
4. Style: tokens on `:root`, one accent color for every CTA, a type scale, 8 px spacing grid, section padding 64 to 120 px on desktop and 48 px on phone. Mobile first; breakpoints near 768 and 1100 px.
5. Add `<head>` essentials: `<title>`, meta description under 160 characters, viewport, Open Graph tags (`og:title`, `og:description`, `og:image`), a favicon (inline SVG data URL is fine).
6. Images: put them in `output/<slug>/assets/`, compress them (see `image-editing`), give width, height and `alt`, and `loading="lazy"` below the fold.
7. Forms: by default the button links to a `mailto:` or a placeholder `#signup`. Only wire a form service if the user names one, and never put keys in the page.
8. Preview and screenshot at desktop and phone width; fix and repeat.
9. Offer deployment, but do not deploy until the user says yes.

## Tools on a Mac

- Preview: `open output/<slug>/index.html`.
- Screenshots: `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars --window-size=1440,4000 --screenshot=tmp/full.png file://$PWD/output/<slug>/index.html` and again with `--window-size=390,6000`.
- Local server: `python3 -m http.server 8080 -d output/<slug>`.
- Compress images: `sips -Z 1600 in.png --out assets/in.png`; WebP with `cwebp -q 80` (`brew install webp`).
- Deploy after a yes: Netlify (`npx netlify-cli deploy --dir output/<slug>` then `--prod`), Cloudflare Pages (`npx wrangler pages deploy output/<slug>`), or Vercel (`npx vercel output/<slug>`). These open a browser login; the user signs in themselves.
- Zip to hand off: `ditto -c -k --keepParent output/<slug> output/<slug>.zip`.

## Quality checklist

- The hero says what it is and who it is for without scrolling, at 390 px wide.
- One primary CTA style, repeated at least in the hero and at the end.
- No fabricated claims, customers or numbers; placeholders are obvious.
- Total page weight under about 1.5 MB; largest image under 300 KB.
- Headings in order (one `h1`), links work, `#anchors` scroll to sections.
- Contrast 4.5:1 for text; buttons have hover and `:focus-visible` states.
- Meta description and OG tags filled in.
- Opens correctly straight from the file and from a local server.

## Reply to the user

One to three sentences: the page is ready, the path, and the next step, e.g. "Your landing page is in output/nimbus-site/index.html. I left two testimonial placeholders for real quotes. Want me to deploy it to Netlify?"

## Pitfalls

- Feature-speak headlines ("AI-powered workflow platform") instead of the outcome.
- Five buttons in different colors fighting for attention.
- Made-up testimonials or "trusted by 10,000 teams".
- Absolute paths (`/assets/x.png`) that break when opened as a file; use relative paths.
- Huge unoptimized PNG heroes.
- Deploying, buying a domain or connecting a form service without asking.

Based on: written for Dottie
