---
name: social-media-content
description: Use when the user wants posts written for X, Instagram, TikTok or LinkedIn: "write a tweet about", "caption for this photo", "LinkedIn post", "content calendar", "hooks for my video". Drafts only.
---

# Social Media Content

## When to use

- Drafting posts, captions, threads, video scripts or hooks for X, Instagram, TikTok or LinkedIn.
- Turning one idea, article or launch into versions per platform.
- Planning a two-week content calendar.
- You never post, schedule, like, follow or reply on the user's accounts. You write drafts the user copies and posts.
- Not for long blog posts or newsletters: write those as a document.

## Steps

1. Get the basics, from the request or by asking once: who it's for, the one point of the post, the platform(s), the voice (look at two or three of the user's past posts if they share them), and any link or call to action.
2. Write the hook first. The first line decides whether anyone keeps reading. Patterns that work: a specific number ("I cut our bill 40% in a week"), a surprising claim, a clear promise ("3 settings every Mac user should change"), a question the reader has. Write three hooks and pick the strongest.
3. Write the body for the platform (limits below). One idea per post. Short lines, plain words, concrete details over adjectives.
4. End with one call to action at most: a question, "link in bio", "save this", or the link.
5. Hashtags: 0 to 2 on X and LinkedIn, 3 to 5 relevant ones on Instagram and TikTok. Real tags people use, not a wall of them.
6. Check length per platform with `wc -m` and trim.
7. Save drafts to `output/social-drafts.md`, one `##` heading per platform with the character count after each draft. For a calendar, write `output/content-calendar.csv` (see below) and a short `.md` version.
8. Copy one draft to the clipboard if the user asks: `pbcopy < tmp/x-post.txt`.

## Tools on a Mac

- `wc -m < tmp/post.txt` counts characters (emoji may count as 2 on X; leave margin).
- `pbcopy` to put a draft on the clipboard; `open output/social-drafts.md` to show it.
- `sips -g pixelWidth -g pixelHeight image.jpg` to check image size; `sips -c 1350 1080 in.jpg --out output/ig.jpg` crops to 4:5 for Instagram.
- Platform limits and fits:
  - X: 280 characters for standard accounts (longer only with a paid tier); links count as 23. Threads: 3 to 7 posts, number them.
  - Instagram: caption up to 2,200 characters, about 125 show before "more"; up to 30 hashtags allowed, use 3 to 5. Feed images 1080x1350 (4:5).
  - TikTok: caption up to 4,000 characters; a script with the hook spoken in the first 2 seconds; 9:16, 1080x1920.
  - LinkedIn: posts up to 3,000 characters, about 210 show before "see more"; first two lines carry it; line breaks help.
- Calendar CSV columns: `date,platform,format,hook,post,cta,asset_needed,status` with status `draft`.
- A good two-week mix: about 40% teaching (tips, how-tos), 30% story or behind the scenes, 20% proof (results, examples the user supplied), 10% direct ask (launch, sign-up). Spread posts 3 to 5 per week per platform rather than daily if the user posts alone.
- Video scripts (TikTok, Reels): write as `0-2s hook | 2-20s point | last 3s call to action`, with on-screen text lines marked separately from spoken lines.

## Quality checklist

- Each draft is under the platform limit, with the count shown.
- The hook is in the first line and is specific.
- Facts, numbers and claims come from the user or a source; nothing invented about results or customers.
- No fake testimonials, no impersonating anyone, no misleading health, money or legal claims.
- Paid partnerships or sponsored content are labeled (#ad or the platform's tag) if the user mentioned a sponsor.
- The calendar has 14 days, mixes formats, and doesn't repeat the same hook.

## Reply to the user

One or two sentences, for example "I wrote drafts for X, Instagram and LinkedIn in output/social-drafts.md; the X one is 241 characters and on your clipboard." Remind them you didn't post anything only if they might assume you did.

## Pitfalls

- Pasting the same text everywhere. Each platform reads differently; at least rewrite the hook and length.
- Hashtag walls look like spam and reduce reach on LinkedIn and X.
- Links in the post body can lower reach on some platforms; offer the link as a first comment the user adds, and say why.
- Burying the point after a long setup.
- Trend audio, memes and current events go stale fast; check they're still current before suggesting them.
- Mentioning or tagging real people or brands in a way that suggests they endorse the user.
- Never log in to, post to, or schedule on any account, even if asked to "just post it"; hand the draft back and let the user post.

Based on: written for Dottie
