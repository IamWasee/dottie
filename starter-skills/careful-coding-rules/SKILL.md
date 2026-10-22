---
name: careful-coding-rules
description: Use for any coding task, big or small ("write code", "change this", "add", "fix", "refactor"). Think first, do the simplest thing, change only what was asked, and define success before starting.
---

# Careful Coding Rules

## When to use

- Every time you write or change code. These are working habits, not a separate phase.
- Especially in someone else's project, where unasked changes cost them review time.

For bigger work, pair with brainstorming-before-building (unclear goal), writing-plans (many steps), test-driven-development (behavior to check) and verification-before-done (finishing).

## Steps

1. Think before typing. Restate the request to yourself in one sentence. If it has two plausible meanings that lead to different code, ask the user one short question instead of guessing. If the meanings lead to the same code, pick one and note it.
2. State your assumptions. Write down what you are assuming about inputs, environment and scope. Put non-obvious ones in your reply.
3. Define success before starting. Turn the request into checks: "running `python3 convert.py in.csv` writes out.json with 120 records", "the test `test_rejects_empty_name` passes". You are done when the checks pass, not when the code looks finished.
4. Read the surrounding code. Match its style, naming, error handling and libraries. Use what the project already has before adding a dependency.
5. Do the simplest thing that meets the checks. No extra options, layers, abstractions, config flags or "future-proofing" nobody asked for. Three similar lines are better than a premature helper.
6. Make surgical changes. Touch only the lines the task needs. Do not reformat files, rename things, reorder imports, fix unrelated warnings or "clean up" nearby code. If you spot a real problem elsewhere, mention it in the reply instead of fixing it.
7. Clean up only your own mess: remove imports, variables and files your change made unused. Do not remove pre-existing dead code unless asked.
8. Keep the diff readable: `git diff` should read like a direct answer to the request. If the diff contains a change you cannot tie to the request, revert it.
9. Run the checks from step 3 and read the output (verification-before-done).
10. Stop when the checks pass. Do not keep polishing.

## Tools on a Mac

- See what you changed: `git diff`, `git diff --stat`, `git status --short`.
- Revert one stray hunk interactively is not available headless; instead restore a whole file you did not mean to change: `git restore path/to/file`.
- Check you did not reformat a file: `git diff --ignore-all-space --stat` compared with `git diff --stat`; a big gap means whitespace churn.
- Find existing helpers before writing new ones: `grep -rn "def parse\|function parse\|func parse" .`
- Check for an existing dependency: `grep -n '"dependencies"' -A 30 package.json`, `cat requirements.txt`, `python3 -m pip show <pkg>`.
- Formatters only if the project already uses them: `npx prettier --check <changed files>`, `ruff format <changed files>`, never on the whole repo.

## Quality checklist

- Success checks were written down before coding and all pass now.
- Every line in `git diff` traces back to the request.
- No new dependency, file, option or abstraction that the task did not need.
- Style matches the surrounding code.
- Assumptions and anything you noticed but did not fix are in the reply.

## Reply to the user

"Done: <what changed, in one sentence>. Checked with <command>: <result>." Add one sentence for any assumption or an issue you noticed but left alone.

## Pitfalls

- Silently choosing one meaning of an ambiguous request and building a lot on it.
- Rewriting a working function "while you are there".
- Running a formatter over the whole file or repo, burying a 3-line fix in 300 lines of diff.
- Adding a settings option instead of making a decision.
- Adding a library for something the standard library does in five lines.
- Declaring done because the code compiles.

Based on: forrestchang/andrej-karpathy-skills
