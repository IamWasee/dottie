---
name: webapp-testing
description: Use when the user wants a local web app checked or tested in a browser: "test my site", "does the signup flow work", "take screenshots of localhost", "why is the page blank", "check for console errors".
---

# Webapp Testing

## When to use

- Testing a web app the user is building, running on `localhost` or from a folder on the Mac.
- Walking through user flows (sign up, add to cart, submit a form), catching console errors, taking screenshots at different sizes.
- Not for collecting data from other people's sites: use `web-scraping-politely`.
- Not for testing live production sites with real accounts or payments without the user's explicit yes.

## Steps

1. Find out how the app starts. Read `package.json` scripts, `README`, `Makefile`, `manage.py` or `vite.config.*`. Note the port.
2. Check whether it is already running: `lsof -nP -iTCP:3000 -sTCP:LISTEN`. If not, start it in the background and log output: `npm run dev > tmp/server.log 2>&1 &` and save the PID (`echo $! > tmp/server.pid`).
3. Wait until it answers: `for i in $(seq 1 30); do curl -sf http://localhost:3000 >/dev/null && break; sleep 1; done`. If it never comes up, read `tmp/server.log` and report the error.
4. Do a first look: load the page in headless Chromium, take a full-page screenshot, and collect console messages and failed requests.
5. Find selectors from what is actually rendered: dump `page.content()` or list `page.get_by_role("button").all_inner_texts()`. Prefer role and text locators (`get_by_role("button", name="Sign up")`, `get_by_label("Email")`) over CSS classes.
6. Write each flow as a small script in `tmp/test_<flow>.py`: steps, an `expect(...)` assertion after each important step, and a screenshot at the end or on failure.
7. Check common sizes: desktop 1440x900 and phone 390x844.
8. Run, read the results, and if something fails, look at the screenshot and console log before deciding if it is an app bug or a test mistake.
9. Write `output/test-report.md`: what was tested, pass/fail per flow, each bug with steps to reproduce, console errors, and screenshot paths in `output/screenshots/`.
10. Stop the server you started: `kill $(cat tmp/server.pid)`. Leave alone a server the user had running.

## Tools on a Mac

- `python3 -m pip install --user playwright pytest-playwright && python3 -m playwright install chromium`.

```python
from playwright.sync_api import sync_playwright, expect
with sync_playwright() as playwright:
    browser = playwright.chromium.launch()
    page = browser.new_page(viewport={"width": 1440, "height": 900})
    console_messages, failed_requests = [], []
    page.on("console", lambda message: console_messages.append(f"{message.type}: {message.text}"))
    page.on("requestfailed", lambda request: failed_requests.append(request.url))
    page.goto("http://localhost:3000", wait_until="networkidle")
    page.get_by_label("Email").fill("test@example.com")
    page.get_by_role("button", name="Sign up").click()
    expect(page.get_by_text("Check your inbox")).to_be_visible()
    page.screenshot(path="output/screenshots/signup-done.png", full_page=True)
    browser.close()
```

- `lsof -nP -iTCP -sTCP:LISTEN` lists servers that are running; `curl -sI http://localhost:3000` checks status.
- Static folder with no server: `python3 -m http.server 8000 --directory site/`.
- `qlmanage -t -s 1000 -o tmp output/screenshots/home.png` for a quick thumbnail.

## Quality checklist

- The app was confirmed up before testing, and the URL and port are in the report.
- Every flow has an assertion, not only clicks.
- Console errors and failed network requests are listed, even when flows pass.
- Screenshots exist for each flow and each failure.
- Bugs have clear reproduction steps.
- Any server you started is stopped; no stray processes left (`pgrep -fl node`).

## Reply to the user

One to three sentences: how many flows passed, the most important bug, and the path, for example "3 of 4 flows pass; checkout fails because the Pay button stays disabled on phone width. The report and screenshots are in output/test-report.md."

## Pitfalls

- Clicking before the page is ready. Use locators and `expect`, not `time.sleep`.
- Using `wait_until="networkidle"` on apps that keep a socket open; fall back to `"load"` plus an `expect`.
- Fixing the app's code when asked only to test it. Report bugs; change code only if the user asked.
- Real emails, payments or production data: use test accounts and fake data like `test@example.com`.
- Leaving a dev server running on the user's port.

Based on: anthropics/skills "webapp-testing"
