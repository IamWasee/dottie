import json, os, subprocess, time
from playwright.sync_api import sync_playwright
HERE = os.path.dirname(os.path.abspath(__file__))
os.makedirs("out", exist_ok=True)
screen = json.loads(subprocess.check_output(["./pointlab", "--screen"]))
SW, SH = int(screen["w"]), int(screen["h"])
def front():
    subprocess.run(["osascript", "-e", 'tell application "Google Chrome" to activate'], capture_output=True)
    time.sleep(1.5)
with sync_playwright() as p:
    b = p.chromium.launch(channel="chrome", headless=False, args=[f"--window-position=0,0", f"--window-size={SW},{SH}", "--no-first-run"])
    ctx = b.new_context(no_viewport=True, locale="en-US")
    page = ctx.new_page()
    # 1. Why does the vision step come back empty?
    page.goto("file://" + HERE + "/shorts.html"); time.sleep(2); front()
    cases = [{"id": "like|dbg", "label": "like button", "question": "where's the like button?", "roughX": 700, "roughY": 500, "gt": None},
             {"id": "bell|dbg", "label": "notification bell", "question": "where are my notifications?", "roughX": 800, "roughY": 200, "gt": None}]
    json.dump(cases, open("out/dbg-cases.json", "w"))
    r = subprocess.run(["./pointlab", "out/dbg-cases.json", "out/dbg-results.json"], capture_output=True, text=True, timeout=300)
    print("POINT DEBUG\n" + r.stderr[-6000:], flush=True)
    print(open("out/dbg-results.json").read(), flush=True)
    # 2. The scroll-and-click job.
    for url, task in [("file://" + HERE + "/roblox.html", "scroll down and click on build a golem"),
                      ("https://www.roblox.com/charts", "scroll down and click on any game in the second row")]:
        try:
            page.goto(url, timeout=45000); time.sleep(5); front()
            r = subprocess.run(["./pointlab", "--task", task], capture_output=True, text=True, timeout=600)
            print("TASK", url, "\n", r.stdout, "\n", r.stderr[-12000:], flush=True)
            print("TITLE AFTER:", page.title(), page.url, flush=True)
            subprocess.run(["./pointlab", "--shot", "out/task-" + str(abs(hash(url)) % 1000) + ".png"])
        except Exception as e:
            print("TASK ERROR", url, e, flush=True)
    b.close()
