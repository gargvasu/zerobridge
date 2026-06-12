import json
import glob
import subprocess
import sys
import time
from datetime import datetime
from Quartz import NSEvent
from AppKit import NSScreen, NSPasteboard, NSPasteboardTypeString, NSWorkspace

# ── Logging ───────────────────────────────────────────

def ts():
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]

def log(symbol, msg, color=None):
    colors = {
        'green':  '\033[92m',
        'red':    '\033[91m',
        'yellow': '\033[93m',
        'blue':   '\033[94m',
        'gray':   '\033[90m',
        'reset':  '\033[0m',
    }
    c = colors.get(color, '')
    r = colors['reset']
    print(f"{colors['gray']}[{ts()}]{r} {c}{symbol}{r} {msg}", flush=True)

def log_info(msg):    log('ℹ', msg, 'blue')
def log_recv(msg):    log('←', msg, 'green')
def log_send(msg):    log('→', msg, 'yellow')
def log_error(msg):   log('✗', msg, 'red')
def log_warn(msg):    log('⚠', msg, 'yellow')
def log_ok(msg):      log('✓', msg, 'green')
def log_raw(msg):     log('~', msg, 'gray')

# ── Port Detection ────────────────────────────────────

ports = glob.glob('/dev/tty.usbmodem*')
if not ports:
    log_error("No serial port found! Is Pi Zero connected?")
    sys.exit(1)

port = ports[0]
log_ok(f"Found port: {port}")
if len(ports) > 1:
    log_warn(f"Multiple ports found: {ports} — using first")

# ── Mac Data Functions ────────────────────────────────

def get_cursor():
    pos = NSEvent.mouseLocation()
    return {"x": round(pos.x, 1), "y": round(pos.y, 1)}

def get_screens():
    screens = []
    for i, s in enumerate(NSScreen.screens()):
        f = s.frame()
        screens.append({
            "id": i,
            "x": int(f.origin.x),
            "y": int(f.origin.y),
            "w": int(f.size.width),
            "h": int(f.size.height)
        })
    screens.sort(key=lambda s: s['x'])
    return screens

def get_clipboard():
    pb = NSPasteboard.generalPasteboard()
    return pb.stringForType_(NSPasteboardTypeString) or ""

def get_active_app():
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    return {"name": app.localizedName(), "window": ""}

# ── Request Handler ───────────────────────────────────

def handle(req: dict) -> dict:
    rid   = req.get("id", "")
    rtype = req.get("type", "")

    t0 = time.monotonic()

    if rtype == "get_cursor":
        data = get_cursor()
        resp = {"id": rid, "type": "cursor_pos", **data}

    elif rtype == "get_screens":
        layout = get_screens()
        resp = {"id": rid, "type": "screens", "layout": layout}
        log_info(f"Screen layout: {len(layout)} screens")
        for s in layout:
            log_info(f"  Screen {s['id']}: x={s['x']} y={s['y']} {s['w']}x{s['h']}")

    elif rtype == "get_clipboard":
        text = get_clipboard()
        resp = {"id": rid, "type": "clipboard", "text": text}
        preview = text[:50] + "..." if len(text) > 50 else text
        log_info(f"Clipboard: {repr(preview)} ({len(text)} chars)")

    elif rtype == "get_active_app":
        app = get_active_app()
        resp = {"id": rid, "type": "active_app", **app}
        log_info(f"Active app: {app['name']}")

    elif rtype == "run_command":
        cmd = req.get("cmd", "")
        log_info(f"Running command: {cmd}")
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        resp = {
            "id": rid,
            "type": "command_result",
            "output": result.stdout,
            "error": result.stderr
        }
        if result.returncode != 0:
            log_warn(f"Command exited {result.returncode}: {result.stderr.strip()}")

    else:
        log_warn(f"Unknown request type: {rtype}")
        resp = {"id": rid, "type": "error", "message": f"Unknown: {rtype}"}

    elapsed = (time.monotonic() - t0) * 1000
    log_info(f"Handled {rtype} in {elapsed:.1f}ms")
    return resp

# ── Stats ─────────────────────────────────────────────

stats = {
    "requests":  0,
    "responses": 0,
    "errors":    0,
    "started":   time.monotonic(),
}

# ── Main Loop ─────────────────────────────────────────

log_ok("Agent ready — waiting for requests...")
log_info(f"PID: {subprocess.os.getpid()}")

ser_in  = open(port, 'r', buffering=1)
ser_out = open(port, 'w', buffering=1)

try:
    for line in ser_in:
        raw = line.strip()
        if not raw:
            continue

        log_raw(f"Raw input: {raw}")
        stats["requests"] += 1

        try:
            req = json.loads(raw)
            rid = req.get("id", "?")[:8]  # short id for logs
            log_recv(f"[{rid}] type={req.get('type')} id={req.get('id')}")

            resp = handle(req)

            json_resp = json.dumps(resp)
            ser_out.write(json_resp + '\n')
            ser_out.flush()

            stats["responses"] += 1
            log_send(f"[{rid}] {json_resp[:120]}")

        except json.JSONDecodeError as e:
            stats["errors"] += 1
            log_error(f"JSON parse error: {e}")
            log_error(f"Raw was: {raw}")

        except Exception as e:
            stats["errors"] += 1
            log_error(f"Handler error: {type(e).__name__}: {e}")
            import traceback
            traceback.print_exc()

except KeyboardInterrupt:
    elapsed = time.monotonic() - stats["started"]
    print()
    log_info("Agent stopped")
    log_info(f"Uptime: {elapsed:.1f}s")
    log_info(f"Requests:  {stats['requests']}")
    log_info(f"Responses: {stats['responses']}")
    log_info(f"Errors:    {stats['errors']}")

finally:
    ser_in.close()
    ser_out.close()