---
name: code-review
description: Use when asked to review code, a diff, a branch, a pull request or a folder ("review this", "is this safe to merge", "check my code"). Report findings ranked P0 to P3 with file:line.
---

# Code Review

## When to use

- The user asks for a review of uncommitted changes, a branch, a commit range, a PR or a folder.
- Before merging or shipping your own non-trivial change, as a second look.

Do not use when:

- The user wants a known bug fixed. Use systematic-debugging.
- The review is only about security. Use secure-coding for the deeper checklist, then come back for anything else.

## Steps

1. Pin down what to review. Uncommitted: `git diff` and `git diff --staged`. Branch: `git diff main...HEAD`. PR: `gh pr diff <number>` if gh is set up. Folder: list files with `git ls-files <folder>`.
2. Understand the intent first: commit messages (`git log main..HEAD --oneline`), PR description, linked design or plan. A review judges the code against what it is meant to do.
3. Read every changed file in full, not just the diff hunks, and the callers of changed functions (`grep -rn "funcName(" .`). Bugs often sit where the change meets unchanged code.
4. Run what exists: tests, type checker, linter. Note failures as findings; do not fix them unless asked.
5. Check, in this order:
   - Correctness: logic errors, off-by-one, wrong conditions, null or empty handling, error paths that swallow failures, races, wrong units or time zones, behavior the intent did not ask for.
   - Security: untrusted input reaching shell, SQL, HTML, file paths or eval; secrets in code; missing auth checks; unsafe deserialization.
   - Data safety: migrations that lose data, deletes without confirmation, writes without backups.
   - Performance: queries or network calls inside loops, unbounded memory, work repeated on every call, blocking the main thread.
   - Tests: new behavior covered, edge cases tested, tests that would actually fail if the code broke.
   - Readability: unclear names, dead code, duplicated logic, comments that lie, functions doing too much.
6. Rank each finding:
   - P0: will break production, lose data or open a security hole. Must fix before merge.
   - P1: real bug or risk in a likely path. Should fix before merge.
   - P2: edge-case bug, missing test, maintainability problem. Fix soon.
   - P3: nit or style suggestion. Optional.
7. Write each finding as: `[P1] src/api.ts:42 - <what is wrong>. <why it matters / when it fails>. Fix: <concrete suggestion>.`
8. Only report what you are confident about. If unsure, say "possible" and what would confirm it. Do not pad with nits to look thorough.
9. Save the full review to `output/code-review.md`: a one-line verdict (approve, approve with fixes, request changes), then findings grouped by priority, then what you checked and found fine.
10. Do not edit the code during a review unless the user asked for fixes.

## Tools on a Mac

- Diffs: `git diff --stat main...HEAD`, `git diff -U10 main...HEAD -- src/` (more context), `git show <sha>`.
- Line numbers for findings: `grep -n "pattern" file`, `nl -ba file | sed -n '30,60p'`.
- GitHub PRs (only if `gh auth status` succeeds): `gh pr view 123`, `gh pr diff 123`, `gh pr checks 123`. Do not post comments to a PR without the user's yes.
- Static checks: `npx tsc --noEmit`, `npx eslint .`, `python3 -m pip install --user ruff && ruff check .`, `swift build`.
- Dependency risk: `npm audit --omit=dev`, `python3 -m pip install --user pip-audit && pip-audit`.
- Secrets scan of the diff: `git diff main...HEAD | grep -nEi '(api[_-]?key|secret|token|password)\s*[:=]'`.

## Quality checklist

- Every finding has a priority, a file:line and a concrete fix.
- P0 and P1 findings are real, with a path that triggers them, not guesses.
- You read the full changed files and key callers, not just hunks.
- You ran the tests and type checks that exist and reported their result.
- The verdict matches the findings (no "approve" with an open P0).

## Reply to the user

"Review saved to output/code-review.md: <verdict>. <N> must-fix issues, the biggest is <one-line P0/P1>." If clean: "Looks good to merge; tests pass and I found only minor nits."

## Pitfalls

- Reviewing only the diff and missing that a changed function is called elsewhere with different assumptions.
- Burying one P0 among twenty style nits.
- Vague findings ("error handling could be better") with no line and no fix.
- Flagging the author's style choices as bugs when the project already does it that way.
- Approving because tests pass, when the tests do not cover the changed lines.
- Silently rewriting the code instead of reporting.

Based on: popular code-reviewer skills
