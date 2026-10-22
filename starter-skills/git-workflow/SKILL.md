---
name: git-workflow
description: Use when working with git or GitHub ("commit this", "make a branch", "merge conflict", "undo my last commit", "push", ".gitignore"). Small commits, safe branches, no force-pushing shared work.
---

# Git Workflow

## When to use

- Starting work in a repository, committing, branching, merging, rebasing or pushing.
- Resolving merge conflicts or undoing a mistake.
- Setting up a new repository or its .gitignore.

Do not use when:

- The user only wants a review of changes. Use code-review.

## Steps

1. Look before acting: `git status`, `git branch --show-current`, `git log --oneline -10`, `git remote -v`. Note uncommitted changes that are not yours; never discard them.
2. New repository: `git init`, add a .gitignore first (step 9), then the first commit.
3. Branch for each piece of work from an up-to-date main: `git switch main && git pull --ff-only && git switch -c feature/short-description` (or `fix/...`). Do not commit straight to main unless the user works that way.
4. Commit small: one logical change per commit, with tests passing. Stage on purpose: `git add <files>` and check `git diff --staged` before committing. Avoid `git add -A` when there may be stray files.
5. Message format: a subject under about 60 characters in imperative mood ("Add CSV export", "Fix crash on empty playlist"), a blank line, then a body saying why if it is not obvious. No "WIP", "stuff", "fixes".
6. Push only when the user asked: `git push -u origin <branch>`. Opening a PR, merging into main, pushing tags or deleting remote branches also wait for the user's yes.
7. Keep a branch current: `git fetch origin` then `git rebase origin/main` for a branch only you use, or `git merge origin/main` for a branch others share.
8. Resolve conflicts:
   - `git status` lists conflicted files. Open each, find `<<<<<<<`, `=======`, `>>>>>>>`.
   - Understand both sides (`git log --oneline -3 origin/main -- <file>`), then write the correct combined code. Do not just pick "ours" for everything.
   - Check no markers remain: `grep -rn '^<<<<<<<\|^>>>>>>>' .`
   - Run tests, then `git add <file>` and `git rebase --continue` or `git commit`. To give up: `git rebase --abort` or `git merge --abort`.
9. .gitignore: ignore build output, dependencies, caches, local env and secrets, OS junk. Typical lines: `.DS_Store`, `node_modules/`, `dist/`, `build/`, `.build/`, `__pycache__/`, `*.pyc`, `.venv/`, `.env`, `*.log`, `DerivedData/`, `xcuserdata/`. If a file is already tracked, `git rm --cached <file>` stops tracking it.
10. Undo safely, least destructive first:
    - Unstage: `git restore --staged <file>`.
    - Throw away your own uncommitted edit to one file: `git restore <file>`.
    - Fix the last unpushed commit: `git commit --amend`.
    - Undo the last unpushed commit but keep the changes: `git reset --soft HEAD~1`.
    - Undo a pushed commit: `git revert <sha>` (adds a new commit; history stays intact).
    - Lost something: `git reflog` shows every recent HEAD; `git switch -c rescue <sha>` brings it back.
11. Before any `git reset --hard`, `git clean -fd`, `git checkout -- .` or branch delete, save a safety point: `git stash push -u -m "before reset"` or `git branch backup/<date>`.

## Tools on a Mac

- git ships with Xcode Command Line Tools: `xcode-select --install` if `git --version` fails.
- Readable history: `git log --oneline --graph --decorate -20`.
- Who changed a line: `git blame -L 40,60 path/to/file`.
- Find when something broke: `git bisect` (see systematic-debugging).
- GitHub CLI if wanted: `brew install gh`; the user signs in themselves with `gh auth login`. Never handle their token.
- Large binaries: `brew install git-lfs`, `git lfs track "*.psd"`.

## Quality checklist

- Work is on a branch with a descriptive name.
- Each commit builds and passes tests, with an imperative subject line.
- No secrets, .env files, build output or .DS_Store committed (`git diff --staged --name-only` checked).
- Nothing pushed, merged or deleted remotely without the user's yes.
- No conflict markers left; tests pass after resolving.

## Reply to the user

"Committed <N> changes on branch <name>: <subject of main commit>. Not pushed yet; say the word and I will push." One or two sentences.

## Pitfalls

- `git push --force` to main or any shared branch. If a force push is truly needed on your own branch, use `git push --force-with-lease` and only with the user's yes.
- `git reset --hard` or `git clean -fd` with someone's uncommitted work in the tree.
- Committing a secret, then "removing" it in the next commit; it stays in history. Tell the user to rotate it.
- One giant commit called "updates".
- Rebasing a branch other people have already pulled.
- Resolving conflicts by keeping one side wholesale without reading the other.

Based on: written for Dottie
