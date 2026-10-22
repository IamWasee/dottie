---
name: email-drafting
description: Use when the user wants an email or reply written: "draft a reply to", "write an email to", "help me answer this", follow-ups, cold emails. Drafts only; never sends.
---

# Email Drafting

## When to use

- Writing a new email, a reply, a follow-up, a polite no, a request or an apology.
- Rewriting the user's rough draft to be clearer, shorter or warmer.
- Several versions of one message (formal and casual).
- Not for team-wide updates or announcements: use `internal-comms`.
- Not for long documents: use `doc-coauthoring`.

This skill never sends email. Sending is the user's action.

## Steps

1. Collect what you need: who it goes to, what the user wants to happen after they read it, the email being answered (pasted or in a file), and any facts to include. If the purpose is unclear, ask one short question.
2. Learn the user's voice. If they have earlier emails or a `voice.md` in the skills library or workspace, read them. Note greeting style, sign-off, length, formality, emoji or not. Otherwise default to plain, friendly and short.
3. Write the draft:
   - Subject line under 8 words that says what the email is about.
   - First line states the point or the ask.
   - Body: only what the reader needs to act; 3 short paragraphs at most.
   - A clear next step with a date if there is one.
   - The user's usual sign-off and name.
4. Replies: answer every question the sender asked, in their order. Quote nothing back unless it helps.
5. Save to `output/emails/<yyyy-mm-dd>-<recipient>-<topic>.txt` with `To:`, `Cc:`, `Subject:` lines on top, then a blank line, then the body.
6. If the user asks to put it in Mail, create an unsent draft with osascript (below). Only when asked, and never with `send`.
7. If the user asks, put the body on the clipboard: `pbcopy < file`.

## Tools on a Mac

- Save and copy: `pbcopy < output/emails/draft.txt`.
- Read a saved email file (.eml): `cat`, or `textutil -convert txt -stdout message.html` for HTML mail.
- Open a Mail draft only when the user asks (it appears in Drafts, not sent):

```bash
osascript <<'APPLESCRIPT'
tell application "Mail"
  set newMessage to make new outgoing message with properties {subject:"Quote for the kitchen job", content:"Hi Sam,

Here is the updated quote...", visible:true}
  tell newMessage to make new to recipient at end of to recipients with properties {address:"sam@example.com"}
end tell
APPLESCRIPT
```

- A `mailto:` link also works for short drafts: `open "mailto:sam@example.com?subject=Quote&body=Hi%20Sam"` (URL-encode with `python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "text"`).
- Word count: `wc -w`.

## Quality checklist

- The ask or point is in the first two lines.
- Every question from the original email is answered.
- Names, dates, amounts and attachments mentioned are correct and match the user's facts.
- Tone fits the relationship (boss, client, friend) and the user's voice.
- Under 150 words unless the content truly needs more.
- No promises or commitments the user did not make.
- Nothing was sent; the draft is saved in `output/emails/`.

## Reply to the user

One or two sentences: what the draft says in a phrase and where it is. For example: "Drafted a short reply to Sam accepting Thursday and asking for the final quote; it's in output/emails/2026-10-22-sam-quote.txt and on your clipboard." If you opened a Mail draft, say it is waiting in Mail for them to review and send.

## Pitfalls

- Never call Mail's `send`, never use command-line mail tools, never post to any service. The user sends.
- Do not invent facts, prices, availability or attachments to make the email complete. Use `[confirm date]` placeholders and mention them.
- Do not read the user's mailbox unless they asked you to look at a specific message.
- Overly formal or flowery language ("I hope this email finds you well") that the user would never write.
- Burying the ask at the end.
- AppleScript strings break on unescaped double quotes; escape them as `\"` or write the body to a file and read it in.
- Leaving out the subject line for a new email.

Based on: written for Dottie
