---
name: customer-support-replies
description: Use when the user needs replies to their app's customers or users: "answer this support email", "reply to this review", "write support macros", "turn this complaint into a bug report".
---

# Customer Support Replies

## When to use

- Drafting replies to support emails, App Store or Play Store reviews, Discord or forum questions about the user's app or product.
- Writing a set of saved replies (macros) for common issues.
- Turning a user's report into a clean bug report for the developer.
- You draft; the user sends. Never send, post or reply on any account yourself.
- Not for marketing posts: use `social-media-content`.

## Steps

1. Read the whole message and any thread. Find: what the person wants, what they tried, device and app version, how upset they are.
2. Check what you know: the user's FAQ, docs, changelog or past replies in the folder (`grep -ril "keyword" .`). Don't guess at features or fixes; if you don't know, say what you need from the owner.
3. Decide the path:
   - **Solve**: you know the answer. Give the steps.
   - **Route**: it's a bug, a billing question, an account change or a legal or privacy request. Acknowledge, say what happens next, and produce a bug report or a note for the owner.
   - **Ask**: missing detail. Ask for the one or two things you need (version, device, screenshot), not a questionnaire.
4. Write the reply: thank or acknowledge in one line, answer in numbered steps if there are steps, close with what happens next. Aim for under 120 words. Match their language.
5. Refunds, credits, discounts, account deletion and promises of dates are the owner's decision only. Write "I've passed this to the team" unless the owner already said yes in this conversation.
6. Save drafts to `output/support-replies.md` with the original message quoted above each reply. Bug reports go to `output/bug-reports.md`.
7. Copy a single reply to the clipboard if asked: `pbcopy < tmp/reply.txt`.

## Tools on a Mac

- `pbcopy` / `pbpaste` to move text in and out of the clipboard.
- `grep -ril` to search the user's docs and past replies; `textutil -convert txt -stdout file.docx` to read docs in Word format.
- `open output/support-replies.md` to show drafts.
- Macro file format, one per issue in `output/support-macros.md`:

```
### Can't sign in
Trigger: "can't log in", "password reset not arriving"
Reply:
Sorry you're locked out. Two things usually fix it:
1. Check spam for the reset email from <sender>.
2. Request a new link; older links stop working after one hour.
If neither works, reply with the email you signed up with and we'll look into it.
```

- Bug report template for `output/bug-reports.md`:

```
### <short title: what breaks, where>
- Reported: <date>, <channel>
- App version / device / OS: <...>
- Steps to reproduce: 1. ... 2. ... 3. ...
- Expected: <...>
- Actual: <...>
- Frequency: always / sometimes / once
- Attachments: <screenshots, logs mentioned>
- User impact: <blocked / annoying / cosmetic>
```

## Quality checklist

- The reply answers the actual question in the first two sentences.
- Kind and plain: no blame, no jargon, no "as previously stated".
- Every step is something the app really has; no invented menus or features.
- No refunds, credits or dates promised without the owner's yes.
- No asking for passwords, full card numbers or codes. Only safe identifiers (account email, order number).
- Public replies (reviews, forums) contain no personal details of the customer.
- Under about 120 words unless steps require more.

## Reply to the user

One or two sentences, for example "I drafted replies to all four emails in output/support-replies.md; two need your call on refunds." Flag anything that needs the owner's decision.

## Pitfalls

- Arguing with an angry review. Acknowledge, fix or route, move on.
- Copy-pasted macros that ignore what the person said. Adjust the first line to their message every time.
- Promising a fix "in the next update" when nobody committed to it.
- Asking for information they already gave.
- Closing a bug as user error without reproducing it.
- Legal threats, chargebacks, privacy or data-deletion requests: don't answer the substance; route to the owner.

Based on: written for Dottie
