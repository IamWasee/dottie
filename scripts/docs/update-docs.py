#!/usr/bin/env python3
"""Keeps CLAUDE.md in step with the code.

Checks (and with --fix, repairs) the parts of CLAUDE.md that can be read
straight from the repository:

  - Key Files table: every Swift file in leanring-buddy/ has a row, no row
    names a file that's gone, and each "~N" line count is within 50 lines
    (or 15%) of the real one. New rows take their purpose from the file's
    header comment, so write a good one when you add a file.
  - Worker routes: every route worker/src/index.ts answers is in the route
    table.
  - Worker settings: every env.X the Worker reads is named in CLAUDE.md.

Usage:
    python3 scripts/docs/update-docs.py          # report, exit 1 when stale
    python3 scripts/docs/update-docs.py --fix    # rewrite CLAUDE.md

Anything it can't write by itself (a route's purpose, a new setting's
meaning) is reported so a person or Claude fills it in. CI runs the check
on pull requests and the fix on main (.github/workflows/docs.yml).
"""
import os
import re
import sys

REPOSITORY_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLAUDE_MD_PATH = os.path.join(REPOSITORY_ROOT, "CLAUDE.md")
SWIFT_SOURCE_FOLDER = os.path.join(REPOSITORY_ROOT, "leanring-buddy")
WORKER_SOURCE_FOLDER = os.path.join(REPOSITORY_ROOT, "worker", "src")

KEY_FILES_ROW_PATTERN = re.compile(r"^\| `([^`]+)` \| ~?(\d+) \| (.*) \|\s*$")
ALLOWED_LINE_COUNT_DRIFT = 50
ALLOWED_LINE_COUNT_DRIFT_FRACTION = 0.15


def count_lines(path):
    with open(path, encoding="utf-8", errors="replace") as source_file:
        return sum(1 for _ in source_file)


def rounded_line_count(line_count):
    return line_count if line_count < 100 else int(round(line_count, -1))


def purpose_from_header_comment(path):
    """The first paragraph of a Swift file's header comment, one line."""
    with open(path, encoding="utf-8", errors="replace") as source_file:
        header_lines = []
        for line in source_file:
            if not line.startswith("//"):
                break
            header_lines.append(line[2:].strip())
    file_name = os.path.basename(path)
    # Skip Xcode's "//", "//  File.swift", "//  leanring-buddy" lines.
    body_lines = [line for line in header_lines if line not in ("", file_name, "leanring-buddy")]
    paragraph = []
    for line in header_lines:
        if line in (file_name, "leanring-buddy"):
            continue
        if not line:
            if paragraph:
                break
            continue
        paragraph.append(line)
    if not paragraph and body_lines:
        paragraph = body_lines[:3]
    text = " ".join(paragraph).replace("|", "/")
    if len(text) > 400:
        cut_text = text[:400]
        last_sentence_end = cut_text.rfind(". ")
        text = cut_text[: last_sentence_end + 1] if last_sentence_end > 120 else cut_text.rstrip() + "…"
    return text or "TODO: describe this file (it has no header comment)."


def swift_files_on_disk():
    return sorted(name for name in os.listdir(SWIFT_SOURCE_FOLDER) if name.endswith(".swift"))


def path_for_listed_file(listed_name):
    if "/" in listed_name:
        return os.path.join(REPOSITORY_ROOT, listed_name)
    return os.path.join(SWIFT_SOURCE_FOLDER, listed_name)


def worker_source_text():
    texts = []
    for name in sorted(os.listdir(WORKER_SOURCE_FOLDER)):
        if name.endswith(".ts"):
            with open(os.path.join(WORKER_SOURCE_FOLDER, name), encoding="utf-8") as source_file:
                texts.append(source_file.read())
    return "\n".join(texts)


def main():
    should_fix = "--fix" in sys.argv[1:]
    with open(CLAUDE_MD_PATH, encoding="utf-8") as claude_md_file:
        claude_md_lines = claude_md_file.read().split("\n")

    problems = []          # stale and fixed by --fix
    needs_a_person = []    # stale, but only a person can write it

    # Key Files table.
    listed_rows = {}
    last_table_row_index = None
    for line_index, line in enumerate(claude_md_lines):
        row_match = KEY_FILES_ROW_PATTERN.match(line)
        if row_match:
            listed_rows[row_match.group(1)] = line_index
            last_table_row_index = line_index
    if last_table_row_index is None:
        print("CLAUDE.md has no Key Files table rows; nothing checked.")
        return 1

    rows_to_remove = set()
    for listed_name, line_index in listed_rows.items():
        listed_path = path_for_listed_file(listed_name)
        if not os.path.exists(listed_path):
            problems.append(f"Key Files lists {listed_name}, which no longer exists")
            rows_to_remove.add(line_index)
            continue
        row_match = KEY_FILES_ROW_PATTERN.match(claude_md_lines[line_index])
        listed_count = int(row_match.group(2))
        actual_count = count_lines(listed_path)
        allowed_drift = max(ALLOWED_LINE_COUNT_DRIFT, int(listed_count * ALLOWED_LINE_COUNT_DRIFT_FRACTION))
        if abs(actual_count - listed_count) > allowed_drift:
            problems.append(f"{listed_name} is listed as ~{listed_count} lines but has {actual_count}")
            claude_md_lines[line_index] = f"| `{listed_name}` | ~{rounded_line_count(actual_count)} | {row_match.group(3)} |"

    new_rows = []
    for swift_file_name in swift_files_on_disk():
        if swift_file_name in listed_rows:
            continue
        swift_file_path = os.path.join(SWIFT_SOURCE_FOLDER, swift_file_name)
        problems.append(f"Key Files has no row for {swift_file_name}")
        new_rows.append(
            f"| `{swift_file_name}` | ~{rounded_line_count(count_lines(swift_file_path))} | {purpose_from_header_comment(swift_file_path)} |"
        )

    # Worker routes and settings.
    worker_text = worker_source_text()
    claude_md_text = "\n".join(claude_md_lines)
    worker_routes = set(re.findall(r'url\.pathname(?: ===|\.startsWith\()\s*"(/[a-z0-9/_-]*)"', worker_text))
    for route in sorted(worker_routes):
        route_name = route.rstrip("/")
        if f"/{route_name.strip('/')}" not in claude_md_text or not re.search(rf"`[A-Z* ]*{re.escape(route_name)}[`/ ?]", claude_md_text):
            needs_a_person.append(f"the Worker answers {route} but the route table doesn't list it")
    for setting_name in sorted(set(re.findall(r"\benv\.([A-Z][A-Z0-9_]+)", worker_text))):
        if setting_name not in claude_md_text:
            needs_a_person.append(f"the Worker reads env.{setting_name} but CLAUDE.md never names it")

    if should_fix and (problems):
        kept_lines = [line for index, line in enumerate(claude_md_lines) if index not in rows_to_remove]
        insert_after = last_table_row_index - sum(1 for index in rows_to_remove if index <= last_table_row_index)
        kept_lines[insert_after + 1:insert_after + 1] = new_rows
        with open(CLAUDE_MD_PATH, "w", encoding="utf-8") as claude_md_file:
            claude_md_file.write("\n".join(kept_lines))
        print(f"Updated CLAUDE.md: {len(problems)} change(s).")
        for problem in problems:
            print(f"  fixed: {problem}")
    else:
        for problem in problems:
            print(f"  stale: {problem}")

    for item in needs_a_person:
        print(f"  write by hand: {item}")

    if should_fix:
        return 0
    if problems or needs_a_person:
        print("\nCLAUDE.md is out of date. Run: python3 scripts/docs/update-docs.py --fix")
        print("(then fill in anything listed under 'write by hand' and any TODO rows)")
        return 1
    print("CLAUDE.md matches the code.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
