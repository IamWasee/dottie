---
name: verification-before-done
description: Use before saying any task is done, fixed, working or passing, for code, files, scripts or documents. Run the real check, read its output, and put the evidence in the reply.
---

# Verification Before Done

## When to use

- At the end of every task, right before the final reply.
- Before any reply containing "done", "fixed", "works", "passes", "ready", "should work".
- Before committing, or before handing work to the user or another helper.

There is no "too small to verify". If a check takes too long to run, say that plainly instead of claiming success.

## Steps

1. Name the claim you are about to make, for example "the tests pass", "the script converts all 40 files", "the bug is fixed".
2. Pick the check that proves exactly that claim:
   - Tests pass: the full test command, not a filtered subset.
   - Build works: the build command, run fresh.
   - Bug fixed: the original reproduction steps, plus the regression test.
   - File created: the file exists, is not empty, and opens as the right type.
   - Script works: run it on real input and inspect the output.
   - Requirements met: re-read the user's request line by line and tick each item.
3. Run the check now, in this turn. Earlier runs do not count after any edit.
4. Read the whole output. Look at the exit code (`echo $?`), the summary line, warnings and counts. "No errors printed" is not the same as success.
5. If the check fails or is unclear, you are not done. Go back to the work (use systematic-debugging if the cause is unknown) and check again.
6. If something cannot be checked here (needs the user's account, another device, a real payment), say exactly what is unverified and how the user can check it.
7. Put the evidence in the reply: the command and the key result, in a few words.

## Tools on a Mac

- Exit codes: `<command>; echo "exit=$?"`. Zero means success for almost every tool.
- Tests: `python3 -m pytest -q`, `npm test`, `swift test`; read the last line (e.g. "42 passed", "Tests: 18 passed").
- Type and lint checks: `npx tsc --noEmit`, `python3 -m pyflakes .` (after `python3 -m pip install --user pyflakes`), `swiftc -typecheck file.swift`.
- Files: `ls -la output/`, `wc -l output/*.csv`, `file output/report.pdf`, `mdls -name kMDItemNumberOfPages output/report.pdf`.
- Images: `sips -g pixelWidth -g pixelHeight output/*.png`.
- Documents: `textutil -convert txt -stdout output/report.docx | head -40` to read what is actually inside.
- JSON and CSV: `python3 -m json.tool output/data.json > /dev/null && echo valid`, `head -5 output/data.csv`.
- Web pages and servers: `curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:3000`.
- Quick visual check: `qlmanage -t -s 800 -o tmp output/report.pdf` makes a thumbnail you can look at.
- Diff against the request: `git diff --stat` to confirm you changed only what was asked.

## Quality checklist

- The check was run after the last edit, in this turn.
- You read the exit code and summary, not just the first lines.
- The check matches the claim (a passing lint is not a passing test).
- Every requirement in the user's message is either met with evidence or listed as not done.
- Nothing in the reply says "should", "probably" or "I believe" about something you could have checked.

## Reply to the user

Lead with the result and the evidence: "Done: all 42 tests pass (pytest) and the report is at output/report.pdf, 6 pages." If partly done: "3 of 4 done; the upload is not tested because it needs your login."

## Pitfalls

- Saying "fixed" because the code looks right.
- Running a filtered test and reporting the whole suite as passing.
- Trusting a helper or a previous run's report instead of checking yourself.
- Missing a failure because output was piped through `head` or `tail` and the exit code was lost.
- Creating a file of 0 bytes, or a .pdf that is really HTML, and calling it done.
- Hiding a failing check by skipping the test or loosening the assertion.

Based on: obra/superpowers "verification-before-completion"
