---
name: systematic-debugging
description: Use when something is broken or behaves wrong ("it crashes", "this error", "tests fail", "it worked yesterday", "why does it..."). Reproduce, gather evidence, find the root cause, then fix.
---

# Systematic Debugging

## When to use

- An error message, crash, failing test, wrong output, hang or slowdown.
- A fix was already tried and did not work. That is a strong signal to slow down and use this.
- Behavior differs between two places (your Mac and CI, yesterday and today).

Do not use when:

- The cause is plain from the error and the fix is one line you can test at once. Fix it, add a regression test, verify.
- The user wants a new feature, not a fix. Use brainstorming-before-building or writing-plans.

## Steps

1. Read the whole error. Read the full stack trace, top and bottom, and note the first line that is in the project's own code. Copy the exact message into `tmp/debug-notes.md`.
2. Reproduce it. Find the smallest command that shows the problem every time, and write it in the notes. If it only happens sometimes, run it in a loop (`for i in $(seq 20); do <cmd> || break; done`) and note how often.
3. Check what changed. `git status`, `git diff`, `git log --oneline -15`, and recently updated dependencies (lock file diffs). If it worked at a known commit, use `git bisect` (see Tools).
4. Gather evidence at the boundaries. Where data passes between parts (function call, file, network, process), print or log what goes in and what comes out. Find the first place where the data is wrong. The bug is between the last good point and the first bad one.
5. Form one hypothesis, written as "X happens because Y". Pick a test that would prove it wrong: a print, a smaller input, a changed variable. Run it.
6. If the hypothesis fails, cross it out in the notes and form the next one. Change one thing at a time. Revert experiments that did not help.
7. Keep tracing backward until you reach the root cause: the original wrong value or wrong assumption, not the line where it finally blew up.
8. Write a failing test that reproduces the bug (see test-driven-development). See it fail.
9. Fix the root cause with the smallest change. Do not also tidy unrelated code.
10. Run the new test, then the whole suite, then the original reproduction command. All must pass.
11. Search for the same mistake elsewhere: `grep -rn` for the pattern you just fixed.
12. If three fixes in a row fail, stop. The model of the system is wrong. Re-read the code from the entry point and question the architecture, and tell the user what you have learned so far.

## Tools on a Mac

- Find a culprit commit: `git bisect start`, `git bisect bad`, `git bisect good <sha>`, then `git bisect run <test command>`; finish with `git bisect reset`.
- Mac app and system logs: `log show --last 10m --predicate 'process == "AppName"' --style compact`; crash reports in `~/Library/Logs/DiagnosticReports/` (`ls -t | head`).
- Python: `python3 -X dev script.py` (extra warnings), `python3 -m pdb script.py`, `python3 -m pytest -x --pdb`, `traceback.print_exc()`.
- Node: `node --trace-warnings app.js`, `node --inspect-brk app.js`, `DEBUG=* npm start` for libraries using the debug package.
- Swift: `swift test --filter Name`, `lldb .build/debug/<binary>` then `run`, `bt` after a crash.
- Network: `curl -v <url>` to see headers and status; `nc -vz host 443` to check a port opens.
- Processes and ports: `lsof -i :3000`, `ps aux | grep <name>`, `top -o cpu -l 1 | head -20`.
- Environment differences: `env | sort > tmp/env.txt`, `which -a python3`, `sw_vers`.

## Quality checklist

- You can state the root cause in one sentence, and the evidence that proves it.
- A regression test exists, failed before the fix and passes after.
- The original reproduction now behaves correctly.
- All debug prints and temporary logging are removed.
- The full test suite passes.

## Reply to the user

"Found it: <root cause in plain words>. Fixed in <file> and added a test so it stays fixed; all tests pass." If not solved: say what is ruled out and the next thing to try.

## Pitfalls

- Guessing a fix from the error line and shipping it without understanding why the bad value got there.
- Changing several things at once, so you cannot tell which one mattered.
- Wrapping the failure in try/except or a nil check that hides the symptom.
- Trusting the error message's location when the real fault is upstream.
- Debugging a stale build: rebuild, clear caches (`rm -rf node_modules/.cache`, `.build`, `__pycache__`) when results look impossible.
- Claiming "fixed" without rerunning the original reproduction.

Based on: obra/superpowers "systematic-debugging"
