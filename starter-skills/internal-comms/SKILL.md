---
name: internal-comms
description: Use when the user needs a message for their team or company: status update, weekly report, project update, announcement, incident note, newsletter, or FAQ.
---

# Internal Comms

## When to use

- Status updates and weekly reports (to a manager, team or leadership).
- Announcements: launches, changes, new hires, policy updates, events.
- Incident notes: what happened, impact, what is being done.
- Team newsletters and FAQs.
- Not for one-to-one email: use `email-drafting`.
- Not for notes from a single meeting: use `meeting-notes` (then feed its output here).

## Steps

1. Identify the type, the audience and the channel (Slack, email, wiki, all-hands slide). Channel decides length: Slack posts under 150 words, emails under 300, wiki pages can be longer.
2. Gather inputs: the user's notes, meeting notes, files, previous updates in the workspace (match their format if one exists). Never invent progress, numbers or dates.
3. Pick the format below and fill it. Lead with what matters most to this audience.
4. Save to `output/comms/<yyyy-mm-dd>-<type>.md`. For Slack, also produce a plain-text version (Slack uses `*bold*`, not `**bold**`).
5. Reread as the busiest person on the list: can they get the point from the first two lines?

## Formats

Status update or weekly report:
```
<Project> update - week of <date>
Status: On track | At risk | Off track (one line why)
Done: 2 to 4 bullets with outcomes, not activity
Next: 2 to 4 bullets with owners and dates
Risks / help needed: bullets, or "None"
```

Leadership summary (3P): Progress, Plans, Problems, 1 to 3 bullets each, metrics where they exist.

Announcement:
```
<Headline that states the news>
What: one or two sentences.
Why: the reason, in one or two sentences.
What it means for you: concrete changes, dates.
Questions: where to ask.
```

Incident note:
```
[Investigating | Identified | Monitoring | Resolved] <short title>
Impact: who or what is affected, since when (time zone).
Current status and next step.
Next update by: <time>.
```
After resolution add: cause in plain words, what fixed it, follow-ups with owners. Blameless: describe systems and steps, not people's mistakes.

Newsletter: 3 to 6 short items, each a bold one-line headline plus two sentences and a link.

FAQ: questions in the reader's words, answers of 1 to 3 sentences, most-asked first.

## Tools on a Mac

- Draft and read in Markdown with `cat`, `rg`.
- Gather recent work if the user points at a git repo: `git -C <repo> log --since="1 week ago" --pretty="- %s (%an)"`.
- Copy the final text: `pbcopy < output/comms/<file>.md`.
- Convert for email or docs: `pandoc in.md -o out.html` or `-o out.docx` (`brew install pandoc`).
- Date math for "week of": `date -v-mon +%Y-%m-%d` (start of this week on macOS `date`).

## Quality checklist

- The first line says the news or the status; no warm-up.
- Every "next" item has an owner and a date.
- Numbers and dates match the sources; nothing invented or rounded into a different claim.
- Bad news is stated plainly, with what is being done about it.
- Fits the channel length; jargon and acronyms explained for the audience.
- Consistent with the format of earlier updates if there are any.

## Reply to the user

One or two sentences: the type of message, its key line, the path. For example: "Wrote the weekly update marking the launch at risk because of the API delay; it's in output/comms/2026-10-22-weekly.md and on your clipboard."

## Pitfalls

- Never post to Slack, send email or publish to a wiki yourself. The user posts it.
- Listing activity ("had meetings about X") instead of outcomes.
- Hiding a slipped date under good news.
- Incident notes that guess at the cause before it is known; say "under investigation".
- Naming or blaming individuals in incident write-ups.
- Markdown that will not render in the target channel (tables in Slack, headings in plain email).

Based on: anthropics/skills "internal-comms"
