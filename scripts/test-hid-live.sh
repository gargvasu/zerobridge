#!/bin/bash
# ── Usage ─────────────────────────────────────────
# Run ON the Pi Zero against a running pi-agent daemon.
# Watch your Mac screen as each test runs.
#
#   ZB_SOCK=/tmp/zb-test.sock ./test-hid-live.sh
#
# Tests:
#   0. Preflight         — ping + channel status
#   1. Chrome check      — detect if Chrome is installed
#   2. Keyboard typing   — notepad.pw (Chrome or Safari)
#   3. Keyboard layout   — key-test.ru (Safari)
#   4. Mouse buttons     — onlinemictest.com/mouse-test (Safari)
#   5. Mouse movement    — webutility.io/mouse-tester (Safari)
#   6. Clipboard         — write + read back (automated PASS/FAIL)
#   7. Focus app         — switch away from Finder (automated PASS/FAIL)
#   8. YouTube           — play/pause + volume OSD

SOCK="${ZB_SOCK:-/tmp/zerobridge.sock}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; GRAY='\033[0;90m'; NC='\033[0m'

PASSED=0; FAILED=0

pass()  { echo -e "${GREEN}✅ $1${NC}"; PASSED=$((PASSED+1)); }
fail()  { echo -e "${RED}❌ $1${NC}"; FAILED=$((FAILED+1)); }
info()  { echo -e "${BLUE}ℹ  $1${NC}"; }
dim()   { echo -e "${GRAY}   $1${NC}"; }
hdr()   { echo ""; echo -e "${BLUE}── $1 ──────────────────────────${NC}"; }
visual(){ echo -e "${YELLOW}👁  $1${NC}"; }

# ── IPC helper ────────────────────────────────────

ipc() {
    echo "$1" | nc -q1 -U "$SOCK" 2>/dev/null
}

ipc_ok() {
    local label="$1" req="$2"
    local resp
    resp=$(ipc "$req")
    if echo "$resp" | grep -qE '"ok"|"type"'; then
        pass "$label"
        dim "$resp"
    else
        fail "$label — got: $resp"
    fi
}

run_cmd() {
    local cmd="$1"
    local escaped
    escaped=$(printf '%s' "$cmd" | sed 's/"/\\"/g')
    ipc "{\"id\":\"run\",\"type\":\"run_command\",\"cmd\":\"$escaped\"}"
}

open_url() {
    local app="$1" url="$2"
    run_cmd "open -a '$app' '$url'" > /dev/null
}

# ── Preflight ─────────────────────────────────────

echo "═══════════════════════════════════════════"
echo "  ZeroBridge — Live HID Test"
echo "  Socket: $SOCK"
echo "  Watch your Mac screen!"
echo "═══════════════════════════════════════════"

[ -S "$SOCK" ] || { echo -e "${RED}❌ Socket not found: $SOCK${NC}"; exit 1; }

PING=$(ipc '{"id":"pre","type":"ping"}')
echo "$PING" | grep -q "pong" || { echo -e "${RED}❌ Daemon not responding${NC}"; exit 1; }
info "Daemon alive"

STATUS=$(ipc '{"id":"s0","type":"status"}')
WS_UP=$(echo "$STATUS"  | grep -o '"ws_healthy":[a-z]*'      | grep -o '[a-z]*$')
USB_UP=$(echo "$STATUS" | grep -o '"ssh_usb_healthy":[a-z]*'  | grep -o '[a-z]*$')
WFI_UP=$(echo "$STATUS" | grep -o '"ssh_wifi_healthy":[a-z]*' | grep -o '[a-z]*$')
info "Channels: ws=$WS_UP  ssh_usb=$USB_UP  ssh_wifi=$WFI_UP"

# ── 1. Chrome check ───────────────────────────────
hdr "1. Chrome check"

CHROME_RESP=$(run_cmd "ls /Applications/Google\\ Chrome.app 2>/dev/null && echo CHROME_FOUND || echo CHROME_MISSING")
CHROME_OUT=$(echo "$CHROME_RESP" | grep -o '"output":"[^"]*"' | sed 's/"output":"//;s/"//')

if echo "$CHROME_OUT" | grep -q "CHROME_FOUND"; then
    pass "Google Chrome is installed"
    BROWSER="Google Chrome"
else
    info "Google Chrome not found — using Safari for all tests"
    BROWSER="Safari"
fi

# ── 2. Keyboard typing — notepad.pw ───────────────
hdr "2. Keyboard typing — notepad.pw"

info "Opening notepad.pw in $BROWSER..."
open_url "$BROWSER" "https://notepad.pw/zerobridge-test"
sleep 4

ipc_ok "focus $BROWSER" "{\"id\":\"kb1\",\"type\":\"focus_app\",\"app\":\"$BROWSER\"}"
sleep 1

# Click centre of screen to focus the textarea
ipc_ok "mouse click (focus textarea)" '{"id":"kb2","type":"mouse_move","dx":0,"dy":0}'
ipc '{"id":"kb3","type":"mouse_click","button":"left"}' > /dev/null
sleep 0.5

# Select all existing text and delete it
ipc '{"id":"kb4","type":"key","code":"A","modifiers":["CMD"]}' > /dev/null
sleep 0.3
ipc '{"id":"kb5","type":"key","code":"DELETE","modifiers":[]}' > /dev/null
sleep 0.3

# Type the test text
ipc_ok "type_smart text" '{"id":"kb6","type":"type_smart","text":"ZeroBridge HID test -- keyboard working! Hello from Pi Zero [ENTER]"}'
sleep 0.5

ipc_ok "type more text" '{"id":"kb7","type":"type_text","text":"abcdefghijklmnopqrstuvwxyz 0123456789"}'

visual "Check notepad.pw — text should have appeared"

# ── 3. Keyboard layout — key-test.ru ──────────────
hdr "3. Keyboard layout — key-test.ru"

info "Opening key-test.ru in Safari..."
open_url "Safari" "https://en.key-test.ru/"
sleep 4

ipc_ok "focus Safari" '{"id":"kl0","type":"focus_app","app":"Safari"}'
sleep 0.5

ipc '{"id":"kl1","type":"mouse_click","button":"left"}' > /dev/null
sleep 0.3

info "Sweeping letter keys A–Z..."
for key in A B C D E F G H I J K L M N O P Q R S T U V W X Y Z; do
    ipc "{\"id\":\"kl_$key\",\"type\":\"key\",\"code\":\"$key\",\"modifiers\":[]}" > /dev/null
    sleep 0.05
done
pass "A–Z sent"

info "Sweeping number keys 0–9..."
for key in 0 1 2 3 4 5 6 7 8 9; do
    ipc "{\"id\":\"kl_n$key\",\"type\":\"key\",\"code\":\"$key\",\"modifiers\":[]}" > /dev/null
    sleep 0.05
done
pass "0–9 sent"

info "Arrow keys and function keys..."
for key in LEFT RIGHT UP DOWN F1 F2 F3 F4; do
    ipc "{\"id\":\"kl_$key\",\"type\":\"key\",\"code\":\"$key\",\"modifiers\":[]}" > /dev/null
    sleep 0.1
done
pass "Arrow + F1–F4 sent"

visual "Check key-test.ru — keys should have lit up"

# ── 4. Mouse buttons — onlinemictest.com ──────────
hdr "4. Mouse buttons — onlinemictest.com/mouse-test"

info "Opening mouse button test..."
open_url "Safari" "https://www.onlinemictest.com/mouse-test/"
sleep 4

ipc_ok "focus Safari" '{"id":"mb0","type":"focus_app","app":"Safari"}'
sleep 0.5

# Move to approximate centre, then click each button
ipc '{"id":"mb1","type":"mouse_move","dx":0,"dy":0}' > /dev/null
sleep 0.3

ipc_ok "left click"   '{"id":"mb2","type":"mouse_click","button":"left"}'
sleep 0.5
ipc_ok "right click"  '{"id":"mb3","type":"mouse_click","button":"right"}'
sleep 0.5
# Dismiss any context menu with Escape
ipc '{"id":"mb4","type":"key","code":"ESC","modifiers":[]}' > /dev/null
sleep 0.3
ipc_ok "middle click" '{"id":"mb5","type":"mouse_click","button":"middle"}'
sleep 0.3

visual "Check onlinemictest.com — left/right/middle buttons should have lit up"

# ── 5. Mouse movement — webutility.io ─────────────
hdr "5. Mouse movement — webutility.io/mouse-tester"

info "Opening mouse movement tester..."
open_url "Safari" "https://webutility.io/mouse-tester"
sleep 4

ipc_ok "focus Safari" '{"id":"mm0","type":"focus_app","app":"Safari"}'
sleep 0.5

info "Drawing a box (right → down → left → up)..."
for i in 1 2 3 4 5 6 7 8; do
    ipc "{\"id\":\"mm_r$i\",\"type\":\"mouse_move\",\"dx\":25,\"dy\":0}" > /dev/null; sleep 0.05
done
for i in 1 2 3 4 5 6 7 8; do
    ipc "{\"id\":\"mm_d$i\",\"type\":\"mouse_move\",\"dx\":0,\"dy\":25}" > /dev/null; sleep 0.05
done
for i in 1 2 3 4 5 6 7 8; do
    ipc "{\"id\":\"mm_l$i\",\"type\":\"mouse_move\",\"dx\":-25,\"dy\":0}" > /dev/null; sleep 0.05
done
for i in 1 2 3 4 5 6 7 8; do
    ipc "{\"id\":\"mm_u$i\",\"type\":\"mouse_move\",\"dx\":0,\"dy\":-25}" > /dev/null; sleep 0.05
done
pass "Box drawn"

info "Drawing a circle (16 diagonal steps)..."
STEPS=(
    "15 -6" "13 -10" "10 -13" "6 -15"
    "-6 -15" "-10 -13" "-13 -10" "-15 -6"
    "-15 6" "-13 10" "-10 13" "-6 15"
    "6 15" "10 13" "13 10" "15 6"
)
i=0
for step in "${STEPS[@]}"; do
    dx=$(echo "$step" | cut -d' ' -f1)
    dy=$(echo "$step" | cut -d' ' -f2)
    ipc "{\"id\":\"mm_c$i\",\"type\":\"mouse_move\",\"dx\":$dx,\"dy\":$dy}" > /dev/null
    sleep 0.06
    i=$((i+1))
done
pass "Circle drawn"

visual "Check webutility.io — should see a box + circle trail"

# ── 6. Clipboard — automated PASS/FAIL ────────────
hdr "6. Clipboard"

CLIP_TEXT="zerobridge-clip-$$"
info "Writing '$CLIP_TEXT' to clipboard via pbcopy..."
run_cmd "echo '$CLIP_TEXT' | pbcopy" > /dev/null
sleep 0.5

CLIP_RESP=$(ipc '{"id":"cl1","type":"get_clipboard"}')
CLIP_GOT=$(echo "$CLIP_RESP" | grep -o '"text":"[^"]*"' | sed 's/"text":"//;s/"//')

if echo "$CLIP_GOT" | grep -q "$CLIP_TEXT"; then
    pass "Clipboard round-trip — got: '$CLIP_GOT'"
else
    fail "Clipboard mismatch — expected '$CLIP_TEXT', got: '$CLIP_GOT'"
fi

# ── 7. Focus app — automated PASS/FAIL ────────────
hdr "7. Focus app"

APP_RESP=$(ipc '{"id":"fa1","type":"get_active_app"}')
CURRENT_APP=$(echo "$APP_RESP" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//')
info "Current active app: $CURRENT_APP"

TARGET="Safari"
[ "$CURRENT_APP" = "Safari" ] && TARGET="iTerm2"

ipc_ok "focus_app → $TARGET" "{\"id\":\"fa2\",\"type\":\"focus_app\",\"app\":\"$TARGET\"}"
sleep 1

APP_RESP2=$(ipc '{"id":"fa3","type":"get_active_app"}')
NEW_APP=$(echo "$APP_RESP2" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//')

if echo "$NEW_APP" | grep -qi "$TARGET"; then
    pass "focus_app worked — now: $NEW_APP"
else
    fail "focus_app failed — expected $TARGET, got: $NEW_APP"
fi

# ── 8. YouTube — play/pause + volume ──────────────
hdr "8. YouTube — play/pause + volume"

info "Opening YouTube in Safari (Me at the zoo)..."
open_url "Safari" "https://www.youtube.com/watch?v=jNQXAC9IVRw"
sleep 6

ipc_ok "focus Safari" '{"id":"yt0","type":"focus_app","app":"Safari"}'
sleep 1

info "Pausing..."
ipc_ok "play_pause (pause)" '{"id":"yt1","type":"media_key","key":"play_pause"}'
sleep 2

info "Resuming..."
ipc_ok "play_pause (resume)" '{"id":"yt2","type":"media_key","key":"play_pause"}'
sleep 1

info "Volume up × 3..."
for i in 1 2 3; do
    ipc_ok "volume_up $i" "{\"id\":\"yt_u$i\",\"type\":\"media_key\",\"key\":\"volume_up\"}"
    sleep 0.4
done

info "Volume down × 3..."
for i in 1 2 3; do
    ipc_ok "volume_down $i" "{\"id\":\"yt_d$i\",\"type\":\"media_key\",\"key\":\"volume_down\"}"
    sleep 0.4
done

visual "Check Safari — video should have paused/resumed + volume OSD appeared"

# ── Release all ───────────────────────────────────

ipc '{"id":"end_rel","type":"release"}' > /dev/null
ipc '{"id":"end_rst","type":"reset"}'   > /dev/null

# ── Summary ───────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════"
echo -e "  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}"
echo ""
echo "  Automated checks: clipboard + focus_app"
echo "  Visual checks:    typing, keys, mouse, YouTube"
echo ""
if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}✅ All automated checks passed${NC}"
else
    echo -e "  ${RED}❌ $FAILED automated check(s) failed${NC}"
fi
echo "═══════════════════════════════════════════"

exit "$FAILED"
