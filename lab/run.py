import json, os, re, time, base64, subprocess, urllib.request, traceback
from playwright.sync_api import sync_playwright
from PIL import Image, ImageDraw

W = os.environ["W"]
OUT = "out"
os.makedirs(OUT, exist_ok=True)
HERE = os.path.dirname(os.path.abspath(__file__))
screen = json.loads(subprocess.check_output(["./pointlab", "--screen"]))
print("screen", screen, flush=True)
SW, SH = int(screen["w"]), int(screen["h"])
calls = []

def chat(model, parts, level=None, timeout=60):
    gc = {"responseMimeType": "application/json", "maxOutputTokens": 2048}
    if level:
        gc["thinkingConfig"] = {"thinkingLevel": level}
    body = {"model": model, "contents": [{"role": "user", "parts": parts}], "generationConfig": gc}
    t = time.time()
    req = urllib.request.Request(W + "/chat", data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "User-Agent": "Dottie/1.0"})
    try:
        raw = urllib.request.urlopen(req, timeout=timeout).read().decode()
    except Exception as e:
        msg = "ERROR " + str(getattr(e, "code", "")) + " " + (e.read().decode()[:160] if hasattr(e, "read") else str(e))
        calls.append((model, time.time() - t, msg[:60]))
        return time.time() - t, msg
    text = ""
    for line in raw.splitlines():
        if line.startswith("data:"):
            try:
                d = json.loads(line[5:])
                for p in d["candidates"][0]["content"]["parts"]:
                    if not p.get("thought") and "text" in p:
                        text += p["text"]
            except Exception:
                pass
    calls.append((model, time.time() - t, "ok"))
    return time.time() - t, text.strip()

def img_part(path):
    return {"inlineData": {"mimeType": "image/jpeg", "data": base64.b64encode(open(path, "rb").read()).decode()}}

def parse_json(text):
    m = re.search(r"[\[{].*[\]}]", text, re.S)
    try:
        j = json.loads(m.group(0)) if m else None
    except Exception:
        return None
    if isinstance(j, list):
        j = j[0] if j and isinstance(j[0], dict) else None
    return j

FIND_JS = r"""
([pattern, attr]) => {
  const re = new RegExp(pattern, 'i');
  const out = [];
  const els = attr ? document.querySelectorAll('[' + attr + ']') : document.querySelectorAll('[aria-label],[title],button,a,yt-formatted-string,span');
  for (const el of els) {
    const name = attr ? el.getAttribute(attr) : (el.getAttribute('aria-label') || el.getAttribute('title') || (el.children.length === 0 ? (el.innerText || '').trim().slice(0, 80) : ''));
    if (!name || !re.test(name)) continue;
    const r = el.getBoundingClientRect();
    if (r.width < 4 || r.height < 4 || r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth) continue;
    const st = getComputedStyle(el);
    if (st.visibility === 'hidden' || st.display === 'none' || +st.opacity === 0) continue;
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    const top = document.elementFromPoint(cx, cy);
    out.push({name, x: r.left, y: r.top, w: r.width, h: r.height, onTop: !!(top && (el.contains(top) || top.contains(el)))});
  }
  return {items: out, sx: screenX, sy: screenY + (outerHeight - innerHeight)};
}
"""

SCENARIOS = [
    {"name": "synthetic", "url": "file://" + HERE + "/shorts.html", "wait": 2, "attr": "data-target", "targets": [
        ("like", "where's the like button?", "^like$", "like button"),
        ("comments", "how do I open the comments?", "^comments$", "comments icon"),
        ("share", "how do I share this?", "^share$", "share button"),
        ("dislike", "where's dislike?", "^dislike$", "dislike button"),
        ("bell", "where are my notifications?", "^bell$", "notifications bell"),
        ("more", "where's the three dots menu?", "^more$", "more options"),
    ]},
    {"name": "shorts", "url": "https://www.youtube.com/shorts/", "wait": 9, "attr": None, "targets": [
        ("like", "where's the like button on this short?", "^like this", "like button"),
        ("comments", "how do I open the comments on this short?", "comment", "comments icon"),
        ("share", "how do I share this short?", "^share$", "share button"),
        ("dislike", "where's the dislike button?", "^dislike this", "dislike button"),
    ]},
    {"name": "watch", "url": "https://www.youtube.com/watch?v=jNQXAC9IVRw", "wait": 9, "attr": None, "targets": [
        ("like", "where's the like button?", "^like this", "like button"),
        ("share", "how do I share this video?", "^share$", "share button"),
        ("settings", "where are the video settings?", "^settings", "settings gear"),
        ("fullscreen", "how do I make it full screen?", "full screen", "fullscreen button"),
    ]},
    {"name": "github", "url": "https://github.com/microsoft/vscode", "wait": 5, "attr": None, "targets": [
        ("star", "how do I star this repo?", "^star$|star this repository|signed in to star", "Star"),
        ("fork", "where do I fork it?", "^fork$|fork your own", "Fork"),
        ("search", "where's the search?", "^search or jump|^search", "search icon"),
    ]},
]

def pick(found):
    items = [i for i in found["items"] if i["onTop"]] or found["items"]
    if not items:
        return None
    items.sort(key=lambda i: i["w"] * i["h"])
    i = items[0]
    return [found["sx"] + i["x"], found["sy"] + i["y"], i["w"], i["h"]], i["name"]

def hit(b, gt, pad=6):
    if not b or not gt:
        return False
    cx, cy = b[0] + b[2] / 2, b[1] + b[3] / 2
    return gt[0] - pad <= cx <= gt[0] + gt[2] + pad and gt[1] - pad <= cy <= gt[1] + gt[3] + pad

def hitp(p, gt, pad=6):
    return bool(p and gt) and gt[0] - pad <= p[0] <= gt[0] + gt[2] + pad and gt[1] - pad <= p[1] <= gt[1] + gt[3] + pad

LIVE_PROMPT = """You are a voice companion looking at the user's screen (this image). The user asked: "{q}".
Answer by calling point_at_element. Reply only JSON {{"x": int, "y": int, "label": string}}: x and y are the element's center, normalized 0 (left/top edge) to 1000 (right/bottom edge); label is the element's visible text or name, exactly as it appears on screen when it has text (like 'Sign in' or 'Downloads'), else a 1-3 word name like 'download icon'."""

ICON_PROMPT = """This is a screenshot of the user's screen. Find this on-screen element: "{label}". The user asked: "{q}".
It may be an icon with no text (a thumbs-up for like, a speech bubble for comments, an arrow for share, a bell for notifications). Look at the whole screen.
Reply with only JSON: {{"box_2d": [ymin, xmin, ymax, xmax]}} normalized 0-1000, tight around the element itself. If it is not visible, reply {{"box_2d": null}}."""

summary = []
with sync_playwright() as p:
    browser = p.chromium.launch(channel="chrome", headless=False, args=[f"--window-position=0,0", f"--window-size={SW},{SH}", "--no-first-run", "--disable-infobars"])
    context = browser.new_context(no_viewport=True, locale="en-US")
    page = context.new_page()
    for sc in SCENARIOS:
        try:
            print("== scenario", sc["name"], flush=True)
            page.goto(sc["url"], wait_until="domcontentloaded", timeout=45000)
            time.sleep(sc["wait"])
            for label in ["Accept all", "Reject all", "No thanks", "Dismiss"]:
                try:
                    page.get_by_role("button", name=label).first.click(timeout=1200)
                    time.sleep(1)
                except Exception:
                    pass
            page.bring_to_front()
            subprocess.run(["osascript", "-e", 'tell application "Google Chrome" to activate'], capture_output=True)
            time.sleep(1.5)
            shot = f"{OUT}/{sc['name']}.png"
            print(subprocess.run(["./pointlab", "--shot", shot], capture_output=True, text=True).stdout.strip(), flush=True)
            im = Image.open(shot).convert("RGB")
            scale = im.width / SW
            live_jpg = f"{OUT}/{sc['name']}-1280.jpg"
            im.resize((1280, int(1280 * im.height / im.width))).save(live_jpg, quality=85)
            big_jpg = f"{OUT}/{sc['name']}-1920.jpg"
            im.resize((1920, int(1920 * im.height / im.width))).save(big_jpg, quality=85)
            cases, extra = [], {}
            for tid, q, pattern, fixed_label in sc["targets"]:
                found = page.evaluate(FIND_JS, [pattern, sc["attr"]])
                picked = pick(found)
                if not picked:
                    print("  target not found:", tid, flush=True)
                    continue
                gt, gname = picked
                dt, out = chat("gemini-3.5-flash", [img_part(live_jpg), {"text": LIVE_PROMPT.format(q=q)}], level="low")
                live = parse_json(out) or {}
                time.sleep(3)
                if isinstance(live, dict) and "point" in live and "x" not in live:
                    live = {"y": live["point"][0], "x": live["point"][1], "label": live.get("label")}
                if "x" in live and "y" in live:
                    rough = [live["x"] / 1000 * SW, live["y"] / 1000 * SH]
                else:
                    rough = [gt[0] + gt[2] / 2 + 60, gt[1] + gt[3] / 2 + 40]
                live_label = live.get("label") or fixed_label
                extra[tid] = {"gt": gt, "gname": gname, "live": live, "liveTime": round(dt, 1), "liveRaw": out[:160]}
                cases.append({"id": f"{tid}|live", "label": live_label, "question": q, "roughX": rough[0], "roughY": rough[1], "gt": gt})
                if fixed_label.lower() != live_label.lower():
                    cases.append({"id": f"{tid}|fixed", "label": fixed_label, "question": q, "roughX": rough[0], "roughY": rough[1], "gt": gt})
                cases.append({"id": f"{tid}|perfect", "label": live_label, "question": q, "roughX": gt[0] + gt[2] / 2, "roughY": gt[1] + gt[3] / 2, "gt": gt, "stages": "novision"})
                # Vision variants on the 1920 screenshot.
                variants = {}
                for vname, model, level, prompt in [
                    ("lite-icon", "gemini-3.5-flash-lite", None, ICON_PROMPT),
                    ("flash-low-icon", "gemini-3.5-flash", "low", ICON_PROMPT),
                    ("f36-low-icon", "gemini-3.6-flash", "low", ICON_PROMPT),
                ]:
                    dt2, out2 = chat(model, [img_part(big_jpg), {"text": prompt.format(label=live_label, q=q)}], level=level)
                    j = parse_json(out2) or {}
                    b = j.get("box_2d")
                    box = None
                    if isinstance(b, list) and len(b) == 4:
                        y0, x0, y1, x1 = b
                        box = [x0 / 1000 * SW, y0 / 1000 * SH, (x1 - x0) / 1000 * SW, (y1 - y0) / 1000 * SH]
                    variants[vname] = {"box": box, "t": round(dt2, 1), "hit": hit(box, gt), "raw": out2[:100]}
                    time.sleep(3)
                extra[tid]["variants"] = variants
                print("  ", tid, json.dumps(extra[tid])[:600], flush=True)
            if not cases:
                continue
            json.dump(cases, open(f"{OUT}/{sc['name']}-cases.json", "w"), indent=1)
            subprocess.run(["osascript", "-e", 'tell application "Google Chrome" to activate'], capture_output=True)
            r = subprocess.run(["./pointlab", f"{OUT}/{sc['name']}-cases.json", f"{OUT}/{sc['name']}-results.json"], capture_output=True, text=True, timeout=600)
            print(r.stderr[-2000:], flush=True)
            results = json.load(open(f"{OUT}/{sc['name']}-results.json"))
            for row in results:
                tid, kind = row["id"].split("|")
                gt = row.get("gt")
                rec = {"scenario": sc["name"], "id": row["id"], "label": row["label"], "words": row["words"], "stage": row["finalStage"],
                       "roughHit": hitp(row["rough"], gt), "finalHit": hit(row.get("final"), gt) if row.get("final") else hitp(row["rough"], gt),
                       "axHit": hit(row.get("ax"), gt) if row.get("ax") else None, "ocrHit": hit(row.get("ocrSnap"), gt) if row.get("ocrSnap") else None,
                       "visionHit": hit(row.get("visionSnap"), gt) if row.get("visionSnap") else None,
                       "visionRawHit": hit(row.get("vision"), gt) if row.get("vision") else None,
                       "times": [round(row["axTime"], 2), round(row["ocrTime"], 2), round(row["visionTime"], 2)]}
                if kind == "live":
                    rec["variants"] = {k: (v["hit"], v["t"]) for k, v in extra[tid]["variants"].items()}
                    rec["liveLabel"] = extra[tid]["live"].get("label")
                summary.append(rec)
                # Annotated image per case.
                a = im.copy()
                d = ImageDraw.Draw(a)
                def rect(b, color, w=4):
                    if b:
                        d.rectangle([b[0] * scale, b[1] * scale, (b[0] + b[2]) * scale, (b[1] + b[3]) * scale], outline=color, width=w)
                rect(gt, (0, 255, 0), 6)
                rect(row.get("ax"), (0, 120, 255))
                rect(row.get("ocrSnap"), (255, 0, 255))
                rect(row.get("vision"), (255, 60, 60))
                rect(row.get("visionSnap"), (255, 160, 0))
                rx, ry = row["rough"][0] * scale, row["rough"][1] * scale
                d.ellipse([rx - 14, ry - 14, rx + 14, ry + 14], outline=(255, 255, 0), width=5)
                f = row.get("final")
                if f:
                    fx, fy = (f[0] + f[2] / 2) * scale, (f[1] + f[3] / 2) * scale
                    d.line([fx - 20, fy - 20, fx + 20, fy + 20], fill=(255, 255, 255), width=6)
                    d.line([fx - 20, fy + 20, fx + 20, fy - 20], fill=(255, 255, 255), width=6)
                if kind == "live":
                    for vname, color in [("lite-icon", (0, 255, 255)), ("flash-low-icon", (180, 0, 255)), ("f36-low-icon", (255, 255, 255))]:
                        rect(extra[tid]["variants"][vname]["box"], color, 2)
                d.text((20, 20), f"{row['id']} label={row['label']!r} stage={row['finalStage']}", fill=(255, 255, 0))
                a.resize((1600, int(1600 * a.height / a.width))).save(f"{OUT}/{sc['name']}-{tid}-{kind}.jpg", quality=80)
        except Exception:
            traceback.print_exc()
    browser.close()

json.dump({"summary": summary, "calls": calls}, open(f"{OUT}/summary.json", "w"), indent=1)
for s in summary:
    print(json.dumps(s))
