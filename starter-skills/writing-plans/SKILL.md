---
name: writing-plans
description: Use when there is an agreed design or clear feature request and the work needs splitting into steps ("plan this", "break it down", "how would we build it"). Writes plan.md with files and checks.
---

# Writing Plans

## When to use

- A design exists (often `output/design.md` from brainstorming-before-building) and the user wants it built.
- A request is clear but touches several files or takes more than one sitting.
- Work will be resumed later, by you or another helper, and needs a written trail.

Do not use when:

- The idea is still vague. Use brainstorming-before-building first.
- The change is one file and a few lines. Just make it and verify it (verification-before-done).

## Steps

1. Read the design and the code it touches. List the existing files you will change with `git ls-files` or `find . -type f -not -path './node_modules/*' -not -path './.git/*'`.
2. Find how the project runs its tests and build: look in package.json "scripts", Makefile, pyproject.toml, Package.swift, README. Note the exact commands. If there is no test setup, the first task is to add one.
3. Split the work into tasks of 2 to 15 minutes each. A task changes one behavior, touches few files and ends in a passing check. If a task needs "and" in its title, split it.
4. Order tasks so each one builds on working code: data model first, then logic, then interface, then polish. Put the riskiest unknown early so it fails fast.
5. Write `output/plan.md` (or `plan.md` in the project root if the user keeps docs there) in this shape:

   ```
   # Plan: <feature>
   Design: output/design.md
   Test command: npm test   (or pytest -q, swift test)

   ## Task 1: <short imperative title>
   Files: src/parser.ts (new), test/parser.test.ts (new)
   Do: <2-5 lines: what to write, function names, inputs and outputs>
   Test first: <the failing test to write and what it asserts>
   Check: npm test -- parser  -> 3 passing
   Commit: "Add parser for routine blocks"
   ```

6. Every task has a Check line: an exact command and the result that means it worked. "Looks right" is not a check.
7. Include the edge cases from the design as their own tests (empty input, huge input, missing file, no network).
8. End the plan with a "Done when" list copied from the design's success criteria, plus "all tests pass" and "README updated if usage changed".
9. Show the user the task titles only (not the whole file) and ask whether to start. When building, tick tasks off in plan.md (`- [x]`) as each check passes, so progress survives a restart.
10. If the plan proves wrong while building, edit plan.md first, then the code. Never let the plan and the code silently drift apart.

## Tools on a Mac

- Map the project: `git ls-files | head -100`, `find . -name '*.swift' | xargs wc -l | sort -n | tail -20`.
- Find where something is defined: `grep -rn "functionName" --include='*.py' .`
- Read scripts: `cat package.json | python3 -m json.tool`, `cat Makefile`.
- Count tasks and progress: `grep -c '^## Task' output/plan.md`, `grep -c '\[x\]' output/plan.md`.
- Open the plan for the user: `open output/plan.md`.
- If `rg` (ripgrep) speeds up searching a big repo: `brew install ripgrep`, then `rg -n "pattern"`.

## Quality checklist

- Each task names exact files (new or changed) and exact functions or types.
- Each task has a runnable check with an expected result.
- No task is bigger than about 15 minutes or touches more than about 3 files.
- Tests come before code inside each task (see test-driven-development).
- The plan covers everything in the design's scope and nothing in "Not in this version".
- A stranger could pick up the plan cold and do task 4 without asking you anything.

## Reply to the user

"The plan is in output/plan.md: <N> tasks, starting with <task 1 title>. Shall I start?" Keep it to one or two sentences.

## Pitfalls

- Tasks like "Implement the backend": too big to check, so nothing is ever clearly done.
- Check lines that say "verify it works" instead of a command.
- Planning against files you have not opened, then discovering they look nothing like you assumed.
- Saving all testing for a final "write tests" task at the end.
- Planning features the design left out because they seemed useful.
- Forgetting setup tasks: installing a test runner, creating a config file, adding a .gitignore.

Based on: obra/superpowers "writing-plans"
