---
name: test-driven-development
description: Use when writing or changing code that has behavior worth checking ("add a feature", "write a function", "fix this bug", "write tests"). Write the failing test first, watch it fail, then make it pass.
---

# Test-Driven Development

## When to use

- Any new function, feature or bug fix in a project that has, or can have, automated tests.
- Fixing a bug: the regression test that reproduces it comes first.
- Refactoring: tests that pin current behavior come before the change.

Do not use when:

- Throwaway exploration ("try calling this API and see what comes back"). Explore, then delete the spike and do it properly with tests.
- Pure config or copy changes with no logic. Verify them with verification-before-done instead.
- You are hunting an unknown cause. Use systematic-debugging, then come back here for the fix.

## Steps

1. Find the test command. Look in package.json "scripts", pyproject.toml, setup.cfg, Package.swift, Makefile. If none exists, set one up (see Tools on a Mac) and commit that first.
2. Red: write one small test for the next bit of behavior. Name it after the behavior: `test_empty_input_returns_empty_list`, `it("rejects a negative amount")`.
3. Run only that test and watch it fail. Read the failure. It must fail for the reason you expect (assertion mismatch, function missing), not a typo, import error or syntax error. If it passes already, the test is wrong or the behavior exists; find out which.
4. Green: write the least code that makes it pass. Hard-coding is fine at this point if the next test will force the general version.
5. Run the test again and see it pass. Then run the whole suite to make sure nothing else broke.
6. Refactor: clean up names and duplication in both code and tests, running the suite after each change. Behavior must not change in this step.
7. Repeat from step 2 with the next behavior: edge cases (empty, zero, one, many, unicode, very large), error paths, then the happy path variants.
8. For a bug: write a test that reproduces the exact bug report, see it fail, fix, see it pass. Keep the test forever.
9. Commit after each green-and-refactored cycle with a message describing the behavior added.

## Tools on a Mac

Python:
- Install once: `python3 -m pip install --user pytest`
- Run all: `python3 -m pytest -q`; one test: `python3 -m pytest -q tests/test_parser.py::test_empty_input -x`
- Stop at first failure and show locals: `python3 -m pytest -x -l`
- Built-in fallback with no install: `python3 -m unittest discover -s tests -v`

JavaScript and TypeScript:
- Run all: `npm test`; pass a filter: `npm test -- parser` (Jest and Vitest both take a name pattern).
- Node 18+ has a built-in runner: `node --test`, test files named `*.test.js` or `*.test.mjs`.
- Add Vitest to a project: `npm install --save-dev vitest`, then `"test": "vitest run"` in package.json.

Swift:
- Swift packages: `swift test`; one test: `swift test --filter ParserTests/testEmptyInput`.
- Tests live in `Tests/<Target>Tests/` and import the module with `@testable import <Target>`.
- Xcode app projects: do not run `xcodebuild` from a helper unless the user asks; it can reset the app's privacy permissions. Put testable logic in a Swift package and `swift test` that.

Other:
- Go: `go test ./...`; Rust: `cargo test`; Ruby: `bundle exec rspec`.
- Watch mode while iterating: `npx vitest`, `python3 -m pip install --user pytest-watch && ptw`.

## Quality checklist

- You saw every new test fail before you wrote the code that passes it.
- Each test checks one behavior and has a name that says which.
- Tests use real inputs and assert on outputs, not on internal calls, unless the outside effect cannot be observed any other way.
- No test depends on the network, the clock or test order; fake or freeze those.
- The full suite passes at the end, and you read the final summary line.

## Reply to the user

"Added <behavior> with <N> new tests; the full suite passes (<X> passed). Code is in <path>." One or two sentences.

## Pitfalls

- Writing the code first and the test after, then never seeing the test fail. A test that never failed may test nothing.
- A test that fails because of an import error, counted as a "red" step.
- Mocking so much that the test only checks the mocks.
- Changing a test's expected value to match buggy output.
- Leaving `.only`, `fit`, `@pytest.mark.skip` or `-x` filters in committed code.
- Huge tests covering five behaviors, so a failure says nothing about which broke.

Based on: obra/superpowers "test-driven-development"
