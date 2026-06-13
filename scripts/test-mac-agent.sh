#!/bin/bash
# ── Usage ─────────────────────────────────────────
# Test the local mac-agent/zb-agent build before installing it.
#
#   ./scripts/test-mac-agent.sh           # test built binary (default)
#   ./scripts/test-mac-agent.sh --serve   # also start server + test WS path
#   ./scripts/test-mac-agent.sh --install # install to ~/bin after tests pass
#
# Exits 0 only if all tests pass.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$REPO_DIR/mac-agent/zb-agent"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; FAILED=$((FAILED + 1)); }
info() { echo -e "${BLUE}ℹ  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }

FAILED=0
DO_SERVE=false
DO_INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --serve)   DO_SERVE=true ;;
        --install) DO_INSTALL=true ;;
        *) echo "Unknown arg: $arg"; exit 1 ;;
    esac
done

echo "═══════════════════════════════════════"
echo "  ZeroBridge — Test mac-agent (zb-agent)"
echo "═══════════════════════════════════════"
echo ""

[ -f "$BINARY" ] || { echo -e "${RED}❌ Binary not found — run: ./scripts/build.sh mac${NC}"; exit 1; }

# ── Helper: run command, check output contains key ──

check() {
    local label="$1"
    local key="$2"     # JSON key that must appear in output
    shift 2
    local output
    output=$("$@" 2>/dev/null)
    if echo "$output" | grep -q "\"$key\""; then
        ok "$label → $output"
    else
        fail "$label — got: $output"
    fi
}

# ── CLI tests ─────────────────────────────────────

info "Testing CLI commands..."

check "cursor"    "type"  "$BINARY" cursor
check "screens"   "layout" "$BINARY" screens
check "clipboard" "type"  "$BINARY" clipboard
check "app"       "type"  "$BINARY" app
check "windows"   "list"  "$BINARY" windows

# focus — use Finder which is always running
FOCUS_OUT=$("$BINARY" focus Finder 2>/dev/null)
if echo "$FOCUS_OUT" | grep -q '"success":true'; then
    ok "focus Finder → $FOCUS_OUT"
else
    fail "focus Finder — got: $FOCUS_OUT"
fi

# window — get Finder window info
WIN_OUT=$("$BINARY" window Finder 2>/dev/null)
if echo "$WIN_OUT" | grep -qE '"app"|"error"'; then
    ok "window Finder → $WIN_OUT"
else
    fail "window Finder — got: $WIN_OUT"
fi

# run — safe read-only command
RUN_OUT=$("$BINARY" run "echo zerobridge-ok" 2>/dev/null)
if echo "$RUN_OUT" | grep -q "zerobridge-ok"; then
    ok "run echo → $RUN_OUT"
else
    fail "run echo — got: $RUN_OUT"
fi

# ── WebSocket server test ─────────────────────────

if [ "$DO_SERVE" = true ]; then
    info "Starting WebSocket server on 127.0.0.1:8082 for test..."
    "$BINARY" serve --port 8082 --bind 127.0.0.1 &
    SERVER_PID=$!
    sleep 1

    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        fail "serve — server failed to start"
    else
        ok "serve — server started (pid $SERVER_PID)"

        # Use Python (always available on macOS) to send a WebSocket request
        WS_OUT=$(python3 - <<'PYEOF' 2>/dev/null
import json, socket, base64, hashlib, os

# Minimal WebSocket handshake over raw TCP
host, port = "127.0.0.1", 8082
key = base64.b64encode(os.urandom(16)).decode()
req = (
    f"GET / HTTP/1.1\r\n"
    f"Host: {host}:{port}\r\n"
    f"Upgrade: websocket\r\n"
    f"Connection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\n"
    f"Sec-WebSocket-Version: 13\r\n\r\n"
)
s = socket.create_connection((host, port), timeout=3)
s.sendall(req.encode())
resp = s.recv(4096).decode(errors="replace")
if "101" not in resp:
    print(json.dumps({"error": "handshake failed", "resp": resp[:200]}))
    s.close()
    exit(1)

# Send a masked WebSocket text frame: {"id":"ws1","type":"ping"}
payload = b'{"id":"ws1","type":"ping"}'
mask = os.urandom(4)
masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
frame = bytes([0x81, 0x80 | len(payload)]) + mask + masked
s.sendall(frame)

# Read response frame (unmasked from server)
header = s.recv(2)
length = header[1] & 0x7F
data = s.recv(length)
print(data.decode())
s.close()
PYEOF
)
        if echo "$WS_OUT" | grep -q '"pong"\|"type"'; then
            ok "WebSocket ping → $WS_OUT"
        else
            fail "WebSocket ping — got: $WS_OUT"
        fi

        # Cursor via WebSocket
        WS_CURSOR=$(python3 - <<'PYEOF' 2>/dev/null
import json, socket, base64, os

host, port = "127.0.0.1", 8082
key = base64.b64encode(os.urandom(16)).decode()
req = (
    f"GET / HTTP/1.1\r\nHost: {host}:{port}\r\n"
    f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
)
s = socket.create_connection((host, port), timeout=3)
s.sendall(req.encode())
s.recv(4096)  # consume handshake

payload = b'{"id":"ws2","type":"get_cursor"}'
mask = os.urandom(4)
masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
frame = bytes([0x81, 0x80 | len(payload)]) + mask + masked
s.sendall(frame)

header = s.recv(2)
length = header[1] & 0x7F
print(s.recv(length).decode())
s.close()
PYEOF
)
        if echo "$WS_CURSOR" | grep -q '"x"'; then
            ok "WebSocket get_cursor → $WS_CURSOR"
        else
            fail "WebSocket get_cursor — got: $WS_CURSOR"
        fi

        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
        ok "Server stopped"
    fi
fi

# ── Summary ───────────────────────────────────────

echo ""
echo "═══════════════════════════════════════"
if [ "$FAILED" -eq 0 ]; then
    ok "All tests passed"
else
    echo -e "${RED}❌ $FAILED test(s) failed${NC}"
fi

# ── Install ───────────────────────────────────────

if [ "$DO_INSTALL" = true ]; then
    if [ "$FAILED" -gt 0 ]; then
        echo -e "${RED}❌ Not installing — tests failed${NC}"
        exit 1
    fi
    info "Installing zb-agent → ~/bin/zb-agent"
    mkdir -p ~/bin
    cp "$BINARY" ~/bin/zb-agent
    ok "Installed → ~/bin/zb-agent"
    echo ""
    echo "To start the WebSocket server:"
    echo "  ~/bin/zb-agent serve --port 8082 --bind 169.254.206.1"
fi

echo "═══════════════════════════════════════"
exit $FAILED
