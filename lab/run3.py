import json, os, subprocess, time
from playwright.sync_api import sync_playwright
HERE = os.path.dirname(os.path.abspath(__file__))
subprocess.run(["v/bin/python", HERE + "/make_items.py"], check=True)
os.makedirs("out", exist_ok=True)
screen = json.loads(subprocess.check_output(["./pointlab", "--screen"]))
SW, SH = int(screen["w"]), int(screen["h"])
def front():
    subprocess.run(["osascript", "-e", 'tell application "Google Chrome" to activate'], capture_output=True); time.sleep(1.5)
with sync_playwright() as p:
    b = p.chromium.launch(channel="chrome", headless=False, args=[f"--window-position=0,0", f"--window-size={SW},{SH}", "--no-first-run"])
    page = b.new_context(no_viewport=True).new_page()
    page.goto("file://" + HERE + "/game.html"); time.sleep(2); front()
    rect = page.evaluate("""() => { const r = document.getElementById('golden').getBoundingClientRect(); return [screenX + r.left, screenY + (outerHeight - innerHeight) + r.top, r.width, r.height] }""")
    print("GOLDEN SWORD GT", rect, flush=True)
    for i in range(2):
        r = subprocess.run(["./pointlab", "--point-ref", "golden sword", HERE + "/ref-golden.jpg"], capture_output=True, text=True, timeout=120)
        print(r.stdout.strip(), flush=True)
        time.sleep(3)
    page.click("body", position={"x": 5, "y": 300}); front()
    for attempt in range(2):
        page.reload(); time.sleep(2); front()
        page.mouse.click(5, 300)
        r = subprocess.run(["./pointlab", "--task", "go grab the golden sword (walk to it and pick it up)", "--game", "--ref", "golden sword", HERE + "/ref-golden.jpg"], capture_output=True, text=True, timeout=900)
        print("GAME RUN", attempt, "\n", r.stdout, flush=True)
        print("\n".join(l[:220] for l in r.stderr.splitlines() if l.startswith(("STEP", "⚠️", "TASK status")) )[-8000:], flush=True)
        print("TITLE AFTER:", page.title(), flush=True)
        subprocess.run(["./pointlab", "--shot", f"out/game-{attempt}.png"])
        if page.title().startswith("PICKED"):
            break
    b.close()
