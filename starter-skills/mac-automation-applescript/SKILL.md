---
name: mac-automation-applescript
description: Use when a task means driving a Mac app by script: "add a reminder", "make a calendar event", "save Safari tabs", "rename these Finder files", Mail, Notes, Music, System Events, via osascript.
---

# Mac Automation with AppleScript

## When to use

- Reading or changing data in scriptable Mac apps: Finder, Safari, Mail, Calendar, Reminders, Notes, Music, Contacts, System Events.
- Small repeatable jobs: list open Safari tabs, add reminders from a list, file Finder items, read today's events.
- Not for running the user's own Shortcuts: use `apple-shortcuts`.
- Not for clicking around apps that have no scripting support: that needs the computer-use skill, if it is on.
- Plain file work (rename, move, convert) is usually simpler with shell commands than with Finder scripting.

## Steps

1. Check that the app is scriptable: `sdef /System/Applications/Reminders.app | grep -m5 '<command'`. No output means no dictionary; use another route.
2. Read before you write. Start with a read-only script (count, list, get properties) and look at the result.
3. Write the script to `tmp/name.applescript` (or `.js` for JXA) instead of long one-liners, then run `osascript tmp/name.applescript`.
4. Pass values as arguments, not by pasting user text into the script: `on run argv` ... `item 1 of argv`, then `osascript tmp/add.applescript "Buy milk" "2026-11-01"`.
5. The first run may trigger a macOS "wants to control" prompt (Automation). If you get error -1743, tell the user to allow it in System Settings > Privacy & Security > Automation, then retry. Never try to bypass it.
6. For writes, do one item first, check it landed, then the rest.
7. Deleting, moving to Trash, sending mail or messages, or changing many items waits for the user's yes. For mail, create a visible draft (`make new outgoing message with properties {visible:true}`) and let the user press Send.
8. Save useful output (lists, exports) to `output/` as `.txt`, `.csv` or `.md`.

## Tools on a Mac

- `osascript -e 'tell application "Safari" to get URL of every tab of front window'`
- `osascript -l JavaScript -e 'Application("Reminders").lists.name()'` for JXA; returns JSON-friendly arrays.
- Reminders: `tell application "Reminders" to make new reminder at end of list "Inbox" with properties {name:"Call Sam", due date:(date "Friday, 1 November 2026 at 09:00")}`. Date strings follow the user's locale; safer to build the date with `current date` and set year, month, day, hours.
- Calendar: `tell application "Calendar" to tell calendar "Home" to make new event with properties {summary:"Dentist", start date:d, end date:d + 3600}`. Reading many events is slow; limit by date with `whose start date > (current date)`.
- Notes: `tell application "Notes" to make new note at folder "Notes" with properties {body:"<h1>Title</h1><p>Text</p>"}` (body is HTML).
- Mail: `tell application "Mail" to get subject of messages 1 thru 10 of inbox`.
- Music: `tell application "Music" to play playlist "Focus"`, `get name of current track`.
- Finder: `tell application "Finder" to get name of every file of (path to downloads folder)`, `reveal POSIX file "/path"`.
- System Events: `tell application "System Events" to get name of every process whose background only is false`; UI scripting (`click menu item ...`) needs Accessibility and breaks easily, so use it last.
- `sdef /Applications/App.app > tmp/app.sdef` to read a full dictionary.
- `open -a "Notes"`, `open -b com.apple.iCal` to launch apps.
- Get JSON out of JXA for parsing: `osascript -l JavaScript -e 'JSON.stringify(Application("Safari").windows[0].tabs.url())' > tmp/tabs.json`.

## Quality checklist

- The script ran on one item before the batch, and the result was checked by reading it back.
- No user text pasted unescaped into script source; arguments used instead.
- Nothing sent, deleted or moved to Trash without the user's yes.
- Dates and times checked in the app (time zone, AM/PM, locale).
- Errors are reported with their number and plain meaning, not swallowed with `try` and ignored.

## Reply to the user

One or two sentences on what changed, for example "I added 5 reminders to your Inbox list, due Friday at 9." If a permission prompt blocked you, say exactly which setting to allow. Point to any export in `output/`.

## Pitfalls

- Error -1743 (not authorized) and -1728 (can't get object) are the common ones; the first is a permission, the second a wrong name or list.
- Calendar and Mail scripts on big accounts can take minutes; filter with `whose` and use `with timeout of 120 seconds`.
- iCloud Notes and Reminders sync slowly; a just-made item may not show on the iPhone right away.
- `display dialog` blocks a headless script waiting for a click nobody sees. Avoid it.
- AppleScript lists start at 1, not 0.
- Quoting: wrap one-liners in single quotes in the shell and use double quotes inside AppleScript; anything more complex goes in a file.
- UI scripting depends on menu names in the user's language and app version.
- Apps launched by a script steal focus; mention it if that may surprise the user.

Based on: written for Dottie
