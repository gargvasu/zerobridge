#!/bin/bash
# ── Usage ─────────────────────────────────────────
# Run ON the Pi Zero. Tests latency at every layer independently.
#
#   ./latency-diag.sh                          # live socket
#   ZB_SOCK=/tmp/zb-test.sock ./latency-diag.sh
#
# Layers tested:
#   0. Network RTT     — ping + TCP connect to mac.hid
#   1. nc overhead     — proves nc -q1 adds ~1000ms
#   2. Per-command     — ping, cursor, clipboard, app, status
#   3. Raw SSH         — bypass pi-agent, bare ssh exec
#   4. Steady-state    — 10x sequential get_cursor, first vs avg
#   5. Channel in use  — infer WS vs SSH from latency
#   6. Concurrent      — 5 parallel vs 5 sequential

SOCK="${ZB_SOCK:-/tmp/zerobridge.sock}"
MAC_HOST="${MAC_HOST:-mac.hid}"
SSH_USER="${SSH_USER:-vasugarg}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; GRAY='\033[0;90m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; }
info() { echo -e "${BLUE}ℹ  $1${NC}"; }
dim()  { echo -e "${GRAY}   $1${NC}"; }
hdr()  { echo ""; echo -e "${BLUE}── $1 ──────────────────────────${NC}"; }

now_ms() { date +%s%3N; }

# Send one IPC request, return response
ipc() { printf '%s\n' "$1" | nc -q0 -U "$SOCK" 2>/dev/null; }

# Time one IPC request, print result line
time_ipc() {
    local label="$1" req="$2"
    local t0 t1 ms resp
    t0=$(now_ms)
    resp=$(ipc "$req")
    t1=$(now_ms)
    ms=$((t1 - t0))
    printf "  %-22s %5dms\n" "$label" "$ms"
    echo "$ms"  # for capture
}

# ── Preflight ─────────────────────────────────────

echo "═══════════════════════════════════════════"
echo "  ZeroBridge — Latency Diagnostic"
echo "  Socket: $SOCK  Mac: $MAC_HOST"
echo "═══════════════════════════════════════════"

[ -S "$SOCK" ] || { echo -e "${RED}❌ Socket not found: $SOCK${NC}"; exit 1; }

PING_RESP=$(ipc '{"id":"pre","type":"ping"}')
echo "$PING_RESP" | grep -q "pong" || { echo -e "${RED}❌ Daemon not responding${NC}"; exit 1; }
info "Daemon alive"

STATUS=$(ipc '{"id":"s0","type":"status"}')
WS_UP=$(echo "$STATUS"  | grep -o '"ws_healthy":[a-z]*'      | grep -o '[a-z]*$')
USB_UP=$(echo "$STATUS" | grep -o '"ssh_usb_healthy":[a-z]*'  | grep -o '[a-z]*$')
info "Bridge status: ws=$WS_UP  ssh_usb=$USB_UP"

# ── 0. Network RTT ────────────────────────────────
hdr "0. Network RTT to $MAC_HOST"

PING_OUT=$(ping -c 5 -q "$MAC_HOST" 2>/dev/null | grep rtt)
if [ -n "$PING_OUT" ]; then
    ok "ICMP ping: $PING_OUT"
else
    t0=$(now_ms)
    if nc -z -w2 "$MAC_HOST" 22 2>/dev/null; then
        t1=$(now_ms)
        ok "TCP connect :22 — $((t1 - t0))ms  (ICMP blocked)"
    else
        fail "Cannot reach $MAC_HOST — check USB ethernet"
    fi
fi

# ── 1. nc -q1 vs nc -q0 overhead ─────────────────
hdr "1. nc -q1 vs nc -q0 overhead"

t0=$(now_ms)
ipc_q1=$(echo '{"id":"nc1","type":"ping"}' | nc -q1 -U "$SOCK" 2>/dev/null)
t1=$(now_ms)
NC_Q1=$((t1 - t0))

t0=$(now_ms)
ipc_q0=$(ipc '{"id":"nc0","type":"ping"}')
t1=$(now_ms)
NC_Q0=$((t1 - t0))

DIFF=$((NC_Q1 - NC_Q0))
echo "  nc -q1: ${NC_Q1}ms"
echo "  nc -q0: ${NC_Q0}ms"
echo "  overhead: ${DIFF}ms"
if [ "$DIFF" -gt 800 ]; then
    ok "nc -q1 adds ~${DIFF}ms — all tests below use nc -q0"
else
    info "nc overhead ${DIFF}ms — latency is real"
fi

# ── 2. Per-command latency ────────────────────────
hdr "2. Per-command latency (nc -q0)"

time_ipc "ping"           '{"id":"c1","type":"ping"}'           > /dev/null
time_ipc "get_cursor"     '{"id":"c2","type":"get_cursor"}'     > /dev/null
time_ipc "get_clipboard"  '{"id":"c3","type":"get_clipboard"}'  > /dev/null
time_ipc "get_active_app" '{"id":"c4","type":"get_active_app"}' > /dev/null
time_ipc "status"         '{"id":"c5","type":"status"}'         > /dev/null

# ── 3. Raw SSH exec (bypasses pi-agent) ───────────
hdr "3. Raw SSH exec latency (bypasses pi-agent)"

if ssh -o ConnectTimeout=3 -o BatchMode=yes "$SSH_USER@$MAC_HOST" true 2>/dev/null; then
    SSH_TOTAL=0
    for i in 1 2 3 4 5; do
        t0=$(now_ms)
        ssh -o BatchMode=yes "$SSH_USER@$MAC_HOST" "echo ok" > /dev/null 2>&1
        t1=$(now_ms)
        ms=$((t1 - t0))
        SSH_TOTAL=$((SSH_TOTAL + ms))
        printf "  raw ssh #%d: %dms\n" "$i" "$ms"
    done
    echo "  avg: $((SSH_TOTAL / 5))ms  (each opens new connection+channel)"
else
    info "SSH not reachable — skipping"
fi

# ── 4. Steady-state: 10x sequential ──────────────
hdr "4. Steady-state — 10x get_cursor"

TOTAL=0; FIRST=0; MIN=9999; MAX=0
for i in $(seq 1 10); do
    t0=$(now_ms)
    ipc "{\"id\":\"ss$i\",\"type\":\"get_cursor\"}" > /dev/null
    t1=$(now_ms)
    ms=$((t1 - t0))
    [ "$i" -eq 1 ] && FIRST=$ms
    TOTAL=$((TOTAL + ms))
    [ "$ms" -lt "$MIN" ] && MIN=$ms
    [ "$ms" -gt "$MAX" ] && MAX=$ms
    printf "  #%2d: %dms\n" "$i" "$ms"
done
AVG=$((TOTAL / 10))
echo ""
echo "  first: ${FIRST}ms  min: ${MIN}ms  avg: ${AVG}ms  max: ${MAX}ms"
if [ "$FIRST" -gt $((AVG * 2)) ]; then
    info "First request slow — connection/process warm-up overhead"
else
    ok "Consistent — no significant warm-up cost"
fi

# ── 5. Channel inference ──────────────────────────
hdr "5. Active channel (inferred from latency)"

MS=$(
    t0=$(now_ms)
    ipc '{"id":"ch1","type":"get_cursor"}' > /dev/null
    t1=$(now_ms)
    echo $((t1 - t0))
)
echo "  get_cursor: ${MS}ms"
if [ "$MS" -lt 100 ]; then
    ok "WebSocket path active (~${MS}ms < 100ms threshold)"
elif [ "$MS" -lt 200 ]; then
    info "SSH path active (~${MS}ms — WS may be down)"
else
    fail "Slow response ${MS}ms — check bridge status"
fi
dim "status: $STATUS"

# ── 6. Concurrent vs sequential ───────────────────
hdr "6. Concurrent vs sequential (5 ping)"

t0=$(now_ms)
for i in 1 2 3 4 5; do
    ipc "{\"id\":\"par$i\",\"type\":\"ping\"}" > /dev/null &
done
wait
t1=$(now_ms)
CONC_MS=$((t1 - t0))

t0=$(now_ms)
for i in 1 2 3 4 5; do
    ipc "{\"id\":\"seq$i\",\"type\":\"ping\"}" > /dev/null
done
t1=$(now_ms)
SEQ_MS=$((t1 - t0))

echo "  concurrent 5x: ${CONC_MS}ms total  (avg $((CONC_MS / 5))ms)"
echo "  sequential 5x: ${SEQ_MS}ms total  (avg $((SEQ_MS / 5))ms)"
SPEEDUP=$((SEQ_MS * 100 / (CONC_MS + 1)))
if [ "$CONC_MS" -lt $((SEQ_MS * 70 / 100)) ]; then
    ok "Concurrency helps (${SPEEDUP}% of sequential time)"
else
    info "Concurrent ≈ sequential — Pi Zero single-core serializing requests"
fi

# ── Summary ───────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════"
echo "  Summary"
echo "  • nc -q1 overhead:  ${DIFF}ms"
echo "  • WS ping baseline: ${NC_Q0}ms"
echo "  • Steady-state avg: ${AVG}ms"
echo "  • Active channel:   $([ "$MS" -lt 100 ] && echo "WebSocket" || echo "SSH fallback")"
echo "═══════════════════════════════════════════"
