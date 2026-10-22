---
name: product-launch-marketing
description: Use when the user is launching an app or product and wants a plan or posts: "help me launch", "write my Product Hunt post", "launch plan", "draft tweets for launch", "how do I market my app".
---

# Product Launch Marketing

## When to use

- Planning a launch for an app, tool, side project or small product.
- Writing launch copy drafts: Product Hunt, Reddit, X, TikTok scripts, email, landing page headline.
- A checklist for launch day.
- Not for pricing decisions or competitor tables: use `pricing-and-competitor-research` first.
- Not for ongoing social posting after launch: use `social-media-content`; for full video scripts use `youtube-tiktok-scripts`; for building the landing page itself use `landing-page`.
- Never posts, submits, emails or schedules anything. Drafts only; the user publishes.

## Steps

1. Gather the facts in `tmp/brief.md`: what the product does in one sentence, who it is for, the problem it solves, what makes it different, price, platform, launch date, links, and any proof (beta users, numbers, quotes). Read the user's site or README if given. Mark gaps as assumptions.
2. Positioning: write a one-line statement, "For <audience> who <problem>, <product> is a <category> that <main benefit>. Unlike <alternative>, it <difference>." Then 3 headline options under 10 words each.
3. Audience: describe 1 or 2 specific groups, where they already hang out online (named subreddits, communities, hashtags, newsletters), and what words they use for the problem.
4. Channels, chosen for the audience, each with how to show up there:
   - **Product Hunt**: launch 12:01 am Pacific, Tuesday to Thursday; tagline up to 60 characters; first comment from the maker telling the story; gallery images 1270x760.
   - **Reddit**: only subreddits whose rules allow self-promotion; lead with the story or a useful lesson; be present to answer comments; no reposting the same text across many subs.
   - **X**: a thread with a short demo video or GIF in the first post; the link in a reply; tag tools used only when relevant.
   - **TikTok / Reels / Shorts**: 15 to 45 second vertical script with a hook in the first 2 seconds, the problem, the product solving it on screen, and a call to action.
   - Also consider: Hacker News "Show HN" (plain, technical, no hype), an email to waitlist or friends, relevant newsletters and communities.
5. Timeline in `output/launch-plan.md`: 2 weeks before (assets, landing page, waitlist), launch week, launch day hour by hour, the week after (reply, thank, collect feedback, share results).
6. Launch-day checklist: site and signup tested on phone and desktop, analytics working, download or payment link working, support email monitored, assets ready, posts drafted, someone available for replies all day.
7. Write drafts in `output/launch-posts.md`, one section per channel, each in that channel's tone and length limits (X 280 characters per post; Product Hunt tagline 60 and description 260). Give 2 variants for the most important post.
8. Add simple measures: what to count (visits, signups, upvotes, comments, conversion), where, and a goal for each.

## Tools on a Mac

- The helper's web search and fetch to read subreddit rules (`https://www.reddit.com/r/<sub>/about/rules.json`) and current Product Hunt guidelines.
- `wc -m` to check character counts: `printf %s "draft text" | wc -m`.
- `sips -z 760 1270 in.png --out output/ph-gallery-1.png` to size a Product Hunt image (crop first if the ratio differs).
- `screencapture -x tmp/shot.png` is for the user's own screen only when the user asks for screenshots of their app.
- `pbcopy < output/launch-posts.md` only if the user asks to copy something.
- `say -v Samantha -f tmp/tiktok-script.txt -o tmp/script.aiff` to hear a video script's pacing.

## Quality checklist

- The positioning names a specific audience and one main benefit, not a list of features.
- Every draft respects its channel's limits and rules; Reddit picks name communities that allow it.
- No invented numbers, testimonials or user counts; claims match the brief.
- Each post has one clear call to action and the right link placeholder (`<LINK>`) where the user must fill it in.
- The checklist has owners and times, not only items.
- Nothing was posted, submitted or sent.

## Reply to the user

Two or three sentences: the positioning line, the recommended main channel and day, and the paths, for example "I'd lead with Product Hunt on Tuesday and r/macapps the same morning. The plan is in output/launch-plan.md and post drafts are in output/launch-posts.md; nothing has been posted."

## Pitfalls

- Spamming many subreddits with the same post gets accounts banned; pick a few and tailor each.
- Asking for upvotes violates Product Hunt and Reddit rules; ask people to check it out and leave feedback instead.
- Hype words ("revolutionary", "game-changing") lower trust, especially on Hacker News.
- Writing for "everyone"; vague audiences make vague copy.
- Fake scarcity or made-up social proof. Do not.
- Launching on a day with a big competing event (a major Apple keynote, a holiday) buries the news; check the calendar.
- Broken links on launch morning; test every link in the drafts the day before.
- Posting, scheduling or DMing on the user's behalf. Hand over drafts; publishing waits for the user.

Based on: written for Dottie
