---
name: apple-shortcuts
description: Use when the user mentions their Shortcuts: "run my shortcut", "what shortcuts do I have", "use my Log Water shortcut", or wants a new shortcut designed for them to build in the Shortcuts app.
---

# Apple Shortcuts

## When to use

- Listing the user's shortcuts or folders.
- Running a shortcut, with or without input, and capturing its output.
- Describing step by step a new shortcut the user can build, when no existing one does the job.
- Not for scripting app data directly (reminders, events, Finder): use `mac-automation-applescript`.
- Shortcuts can't be created or edited from the shell. You describe; the user builds.

## Steps

1. List what exists: `shortcuts list` (names) and `shortcuts list --folders`. For one folder: `shortcuts list --folder-name "Home"`.
2. Match the user's words to a name. Names are case and space sensitive; quote them. If two could fit, ask which one.
3. Before running, think about what the shortcut does. If its name suggests it sends, posts, buys, pays, deletes or controls home devices, ask the user first.
4. Run it:
   - No input: `shortcuts run "Log Water"`
   - Input from a file: `shortcuts run "Resize Image" --input-path tmp/photo.jpg`
   - Text input: `printf '%s' "250 ml" > tmp/in.txt && shortcuts run "Log Water" --input-path tmp/in.txt`
   - Capture output: `shortcuts run "Get Weather" --output-path tmp/out.txt --output-type public.plain-text`
5. Read the output file and check it makes sense. A zero exit code only means it did not crash.
6. If the shortcut asks a question (Ask for Input, Choose from Menu), it will wait on the Mac's screen. Tell the user it is waiting for them instead of retrying.
7. To design a new one, write a short recipe in `output/<name>-shortcut.md`: the name, the trigger (run by voice, from the menu bar, an automation), then the actions in order with the exact action names as they appear in the Shortcuts app ("Get Contents of URL", "Get Dictionary Value", "Show Result"), and what to set in each.
8. After the user builds it, run it once with them and adjust.

## Tools on a Mac

- `shortcuts list`, `shortcuts list --folders`, `shortcuts list --folder-name "X"`
- `shortcuts run "Name" [--input-path file] [--output-path file] [--output-type UTI]`
- `shortcuts view "Name"` opens it in the Shortcuts app for the user to look at or edit.
- `shortcuts sign --mode anyone --input tmp/x.shortcut --output output/x.shortcut` signs a shortcut file for sharing (only if the user exported one).
- Useful output types: `public.plain-text`, `public.png`, `public.jpeg`, `com.adobe.pdf`, `public.json`.
- `open "shortcuts://run-shortcut?name=Log%20Water"` runs it through the app instead of the CLI (shows UI).
- `pbpaste` / `pbcopy` when a shortcut reads from or writes to the clipboard.
- `shortcuts list | grep -i water` to find a name when the user only remembers part of it.
- Check the result type with `file tmp/out.txt` when you asked for one type and might have got another.
- `shortcuts help run` prints the flags this macOS version supports.

## Quality checklist

- The shortcut name matched exactly what `shortcuts list` printed.
- Shortcuts with outside effects ran only after the user's yes.
- Output was read and checked, not just the exit code.
- Recipes use real action names and say which inputs and variables connect.
- Nothing personal (passwords, card numbers) put into a shortcut recipe.

## Reply to the user

One sentence on what ran and what came back, for example "I ran Log Water with 250 ml; it says today's total is 1.5 liters." For a design: "I wrote the steps for a Morning Brief shortcut in output/morning-brief-shortcut.md; it's six actions."

## Pitfalls

- A shortcut that runs fine in the app can fail from the CLI when it needs a permission it never asked for before; the prompt appears on the Mac. Tell the user to check the screen.
- Shortcuts that show a result with "Show Result" print nothing to the CLI; use "Stop and Output" in the design for anything that should return text.
- `--input-path` passes a file, so text must be written to a file first.
- iCloud-synced shortcuts can be edited on the iPhone between runs; list again if a name fails.
- Long-running shortcuts have no timeout from the CLI; macOS has no `timeout` command, so use `gtimeout 120` only if `coreutils` is already installed, otherwise run it in the background and check on it.
- Don't invent action names. If unsure an action exists on this macOS version, say so in the recipe.

Based on: written for Dottie
