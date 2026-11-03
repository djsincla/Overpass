"""Hardware tests through Overpass's Debug test API (App/TestAPI.swift).

Run a Debug build of the Mac app with the API on, the mount on its USB cable, then:

    open path/to/Debug/Overpass.app --args -testAPI YES
    python3 scripts/mount-tests.py normal special      # or wifi

Small moves only, left (azimuth down) and down, so start with the mount pointing well away from
north and from the horizon. After each move it checks the mount is still; if not, it sends Stop
at once and fails. A position question on connecting is answered "go by the mount"."""
import json, sys, time, urllib.request, pathlib

TOKEN = (pathlib.Path.home() / "Library/Application Support/com.djsincla.overpass/test-api-token").read_text().strip()
BASE = "http://127.0.0.1:48123"

def call(method, path):
    req = urllib.request.Request(BASE + path, method=method, headers={"X-Overpass-Token": TOKEN})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)

def where(s):
    a = s.get("axes"); k = s.get("sky")
    if a: return (round(a["primary"], 4), round(a["secondary"], 4))
    if k: return (round(k["azimuth"], 4), round(k["altitude"], 4))
    return None

def still(settle, gap):
    """Waits `settle` s, then compares two positions `gap` s apart."""
    time.sleep(settle)
    a = where(call("GET", "/state")); time.sleep(gap); b = where(call("GET", "/state"))
    moving = a is None or b is None or max(abs(a[0] - b[0]), abs(a[1] - b[1])) > 0.02
    return not moving, a, b

results = []
def record(name, ok, detail):
    results.append((name, ok, detail))
    print(("PASS " if ok else "FAIL ") + name + ": " + detail, flush=True)
    if not ok:
        call("POST", "/stop?unwind=0")
        print("  sent Stop", flush=True)

def taps(label, settle, gap, durations, dirs=("left", "down")):
    for d in dirs:
        for ms in durations:
            before = where(call("GET", "/state"))
            call("POST", f"/tap?dir={d}&ms={ms}")
            ok, a, b = still(settle, gap)
            record(f"{label} tap {d} {ms} ms", ok, f"before {before}, after {a} then {b}")
            if not ok: return False
    return True

def hold(label, settle, gap, d="left", ms=1500):
    before = where(call("GET", "/state"))
    call("POST", f"/tap?dir={d}&ms={ms}")
    ok, a, b = still(settle, gap)
    moved = before is not None and a is not None and max(abs(before[0] - a[0]), abs(before[1] - a[1])) > 0.05
    record(f"{label} hold {d} {ms} ms", ok and moved, f"moved {moved}, stopped {ok}: {before} -> {a} -> {b}")

def background(label, settle, gap, d="left"):
    call("POST", f"/jog?dir={d}&action=press")
    time.sleep(0.8)
    call("POST", "/background")
    ok, a, b = still(settle, gap)
    call("POST", f"/jog?dir={d}&action=release")
    record(f"{label} background while holding {d}", ok, f"{a} then {b}")

def connect(kind):
    port = next(iter(sorted(pathlib.Path("/dev").glob("cu.PL2303*"))), None)
    s = call("POST", f"/connect?kind={kind}" + (f"&port={port}" if port and kind != "wifi" else ""))
    if "question" in s:
        # Go by the mount: it's what the mount will act on, and nothing moves either way.
        print(f"  position question: mount {s['question']['mount']}, record {s['question']['record']}; going by the mount", flush=True)
        s = call("POST", "/answer?position=mount")
    ok = s.get("state") == "connected"
    record(f"connect {kind}", ok, f"{s.get('state')}, mount {s.get('mount')} ({s.get('mountInfo')}), at {where(s)}")
    return ok

def disconnect():
    s = call("POST", "/disconnect")
    record("disconnect", s.get("state") == "disconnected" and not s.get("holdsSpecialMode"), json.dumps({k: s.get(k) for k in ("state", "holdsSpecialMode")}))

which = sys.argv[1:] or ["normal", "special"]
try:
    if "normal" in which and connect("usbNormal"):
        # Normal mode is read once a second: wait for two reads after the tap.
        taps("Normal", 2.5, 2.2, [20, 40, 60, 80, 120])
        hold("Normal", 2.5, 2.2)
        disconnect()
    if "special" in which and connect("usb"):
        taps("Special", 1.0, 1.0, [20, 40, 60, 80, 120])
        hold("Special", 1.0, 1.0)
        background("Special", 1.0, 1.0)
        disconnect()
    if "wifi" in which and connect("wifi"):
        taps("WiFi", 2.5, 2.2, [20, 40, 60, 80, 120])
        hold("WiFi", 2.5, 2.2)
        disconnect()
finally:
    try: call("POST", "/stop?unwind=0")
    except Exception as e: print("final stop failed:", e)
print(f"\n{sum(ok for _, ok, _ in results)}/{len(results)} passed")
for line in call("GET", "/log?lines=25")["lines"]: print("  log:", line)
