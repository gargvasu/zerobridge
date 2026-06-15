#!/bin/bash
# ── Usage ─────────────────────────────────────────
# Run ON the Pi Zero against a running pi-agent daemon.
#
#   ./stress-test-pi.sh                     # test live socket
#   ZB_SOCK=/tmp/zb-test.sock ./stress-test-pi.sh  # test daemon
#
# Tests:
#   1. Sequential throughput  — rapid-fire requests, measure latency
#   2. Concurrent requests    — parallel connections
#   3. All IPC types          — every command type at least once
#   4. Large response         — get_windows (can be big)
#   5. WS failover            — kill WS server mid-test, verify SSH fallback
#   6. WS recovery            — restart WS server, verify WS path resumes
#   7. HID smoke              — key/mouse/media (sends real input to Mac)
#
# Results: PASS/FAIL per test + latency stats

SOCK="${ZB_SOCK:-/tmp/zerobridge.sock}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; GRAY='\033[0;90m'; NC='\033[0m'

PASSED=0; FAILED=0; SKIPPED=0
declare -a LATENCIES=()

pass()  { echo -e "${GREEN}✅ $1${NC}"; PASSED=$((PASSED+1)); }
fail()  { echo -e "${RED}❌ $1${NC}"; FAILED=$((FAILED+1)); }
skip()  { echo -e "${YELLOW}⏭  $1${NC}"; SKIPPED=$((SKIPPED+1)); }
info()  { echo -e "${BLUE}ℹ  $1${NC}"; }
dim()   { echo -e "${GRAY}   $1${NC}"; }
hdr()   { echo ""; echo -e "${BLUE}── $1 ──────────────────────────${NC}"; }

# ── Helpers ───────────────────────────────────────

# ipc REQUEST_JSON [TIMEOUT_MS]  → stdout=response, return=exit code
ipc() {
    local req="$1"
    local t="${2:-3000}"
    echo "$req" | nc -q0 -U "$SOCK" 2>/dev/null
}

# ipc_check LABEL REQ EXPECTED_KEY
ipc_check() {
    local label="$1" req="$2" key="$3"
    local t0 t1 ms resp
    t0=$(date +%s%3N)
    resp=$(ipc "$req")
    t1=$(date +%s%3N)
    ms=$((t1 - t0))
    LATENCIES+=("$ms")
    if echo "$resp" | grep -q "\"$key\""; then
        pass "$label (${ms}ms)"
        dim "$resp"
    else
        fail "$label — got: $resp"
    fi
}

# ── Preflight ─────────────────────────────────────

echo "═══════════════════════════════════════════"
echo "  ZeroBridge — Pi Agent Stress Test"
echo "  Socket: $SOCK"
echo "═══════════════════════════════════════════"

[ -S "$SOCK" ] || { echo -e "${RED}❌ Socket not found: $SOCK${NC}"; exit 1; }

PING=$(ipc '{"id":"pre","type":"ping"}')
echo "$PING" | grep -q "pong" || { echo -e "${RED}❌ Daemon not responding${NC}"; exit 1; }
info "Daemon alive"

STATUS=$(ipc '{"id":"s0","type":"status"}')
WS_UP=$(echo "$STATUS"   | grep -o '"ws_healthy":[a-z]*'  | grep -o '[a-z]*$')
SSH_UP=$(echo "$STATUS"  | grep -o '"ssh_usb_healthy":[a-z]*' | grep -o '[a-z]*$')
WIFI_UP=$(echo "$STATUS" | grep -o '"ssh_wifi_healthy":[a-z]*' | grep -o '[a-z]*$')
info "Channels: ws=$WS_UP  ssh_usb=$SSH_UP  ssh_wifi=$WIFI_UP"

# ── 1. All IPC types ──────────────────────────────
hdr "1. All IPC types"

ipc_check "ping"           '{"id":"t1","type":"ping"}'                       "pong"
ipc_check "get_cursor"     '{"id":"t2","type":"get_cursor"}'                 "x"
ipc_check "get_screens"    '{"id":"t3","type":"get_screens"}'                "layout"
ipc_check "get_clipboard"  '{"id":"t4","type":"get_clipboard"}'              "text"
ipc_check "get_active_app" '{"id":"t5","type":"get_active_app"}'             "name"
ipc_check "get_windows"    '{"id":"t6","type":"get_windows"}'                "list"
ipc_check "focus_app"      '{"id":"t7","type":"focus_app","app":"Finder"}'   "success"
ipc_check "run_command"    '{"id":"t8","type":"run_command","cmd":"echo ok"}' "output"
ipc_check "status"         '{"id":"t9","type":"status"}'                     "ws_healthy"

# ── 2. Sequential throughput ──────────────────────
hdr "2. Sequential throughput (20x get_cursor)"

SEQ_START=$(date +%s%3N)
SEQ_OK=0
for i in $(seq 1 20); do
    r=$(ipc "{\"id\":\"seq$i\",\"type\":\"get_cursor\"}")
    echo "$r" | grep -q '"x"' && SEQ_OK=$((SEQ_OK+1))
done
SEQ_END=$(date +%s%3N)
SEQ_MS=$((SEQ_END - SEQ_START))
SEQ_AVG=$((SEQ_MS / 20))

if [ "$SEQ_OK" -eq 20 ]; then
    pass "20/20 succeeded — total ${SEQ_MS}ms, avg ${SEQ_AVG}ms/req"
else
    fail "$SEQ_OK/20 succeeded — total ${SEQ_MS}ms"
fi

# ── 3. Concurrent requests ────────────────────────
hdr "3. Concurrent requests (10 parallel)"

TMPDIR_CONC=$(mktemp -d)
for i in $(seq 1 10); do
    (
        r=$(ipc "{\"id\":\"par$i\",\"type\":\"get_cursor\"}")
        echo "$r" | grep -q '"x"' && echo "ok" || echo "fail"
    ) > "$TMPDIR_CONC/$i" &
done
wait

CONC_OK=$(grep -l "^ok$" "$TMPDIR_CONC"/* 2>/dev/null | wc -l | tr -d ' ')
CONC_FAIL=$(grep -l "^fail$" "$TMPDIR_CONC"/* 2>/dev/null | wc -l | tr -d ' ')
rm -rf "$TMPDIR_CONC"

if [ "$CONC_OK" -eq 10 ]; then
    pass "10/10 concurrent requests succeeded"
else
    fail "$CONC_OK/10 succeeded, $CONC_FAIL failed"
fi

# ── 4. Mixed workload ─────────────────────────────
hdr "4. Mixed workload (query + HID interleaved)"

READ_OK=0; HID_OK=0
for i in $(seq 1 5); do
    r=$(ipc "{\"id\":\"mix_r$i\",\"type\":\"get_active_app\"}")
    echo "$r" | grep -q '"name"' && READ_OK=$((READ_OK+1))

    r=$(ipc "{\"id\":\"mix_h$i\",\"type\":\"media_key\",\"key\":\"volume_up\"}")
    echo "$r" | grep -q '"ok"\|"type"' && HID_OK=$((HID_OK+1))

    r=$(ipc "{\"id\":\"mix_m$i\",\"type\":\"mouse_move\",\"dx\":0,\"dy\":0}")
    echo "$r" | grep -q '"ok"' && HID_OK=$((HID_OK+1))
done

r=$(ipc '{"id":"mix_reset","type":"reset"}')
echo "$r" | grep -q '"ok"' || fail "reset after mixed workload"

[ "$READ_OK" -eq 5 ] && pass "5/5 read queries in mixed workload" \
                      || fail "$READ_OK/5 read queries in mixed workload"
[ "$HID_OK" -eq 10 ] && pass "10/10 HID commands in mixed workload" \
                       || fail "$HID_OK/10 HID commands in mixed workload"

# ── 5. Large payload ──────────────────────────────
hdr "5. Large response (get_windows)"

t0=$(date +%s%3N)
WINS=$(ipc '{"id":"big1","type":"get_windows"}')
t1=$(date +%s%3N)
WIN_MS=$((t1 - t0))
WIN_LEN=${#WINS}

if echo "$WINS" | grep -q '"list"'; then
    pass "get_windows — ${WIN_LEN} bytes in ${WIN_MS}ms"
    dim "$(echo "$WINS" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f"{len(d[\"list\"])} windows")' 2>/dev/null || echo "?")"
else
    fail "get_windows — got: ${WINS:0:100}"
fi

# ── 6. WS failover (manual, optional) ─────────────
hdr "6. WS failover"

if [ "$WS_UP" = "true" ]; then
    info "WS is healthy — testing failover path"
    info "Kill zb-agent on the Mac now (Ctrl-C in its terminal)"
    info "Press Enter when done, or Ctrl-C to skip this test"

    read -t 15 -r -p "   Waiting (15s timeout)... " && {
        # Give health monitor a moment
        sleep 1
        r=$(ipc '{"id":"fo1","type":"get_cursor"}')
        STATUS2=$(ipc '{"id":"fo2","type":"status"}')
        WS2=$(echo "$STATUS2" | grep -o '"ws_healthy":[a-z]*' | grep -o '[a-z]*$')
        SSH2=$(echo "$STATUS2" | grep -o '"ssh_usb_healthy":[a-z]*' | grep -o '[a-z]*$')

        if echo "$r" | grep -q '"x"'; then
            if [ "$WS2" = "false" ] && [ "$SSH2" = "true" ]; then
                pass "Failover: WS down, SSH took over — cursor: $r"
            else
                pass "get_cursor succeeded after WS kill (ws=$WS2 ssh=$SSH2)"
            fi
        else
            fail "get_cursor failed after WS kill — $r"
        fi

        info "Restart zb-agent on Mac, press Enter to test recovery"
        read -t 15 -r -p "   Waiting (15s timeout)... " && {
            sleep 4  # let health monitor probe
            STATUS3=$(ipc '{"id":"rec","type":"status"}')
            WS3=$(echo "$STATUS3" | grep -o '"ws_healthy":[a-z]*' | grep -o '[a-z]*$')
            if [ "$WS3" = "true" ]; then
                pass "WS recovery: ws_healthy=true after restart"
            else
                fail "WS not recovered yet (ws=$WS3) — may need another probe cycle"
            fi
        } || skip "WS recovery test skipped (timeout)"
    } || skip "Failover test skipped (timeout)"
else
    skip "WS failover — WS not healthy at start (ws=$WS_UP)"
fi

# ── 7. HID smoke test ─────────────────────────────
hdr "7. HID smoke test (sends real input to Mac)"

info "This sends a Cmd+Space then Escape — watch your Mac"
sleep 1

ipc_check "key CMD+SPACE"  '{"id":"hid1","type":"key","code":"SPACE","modifiers":["CMD"]}' "ok"
sleep 0.5
ipc_check "key ESC"        '{"id":"hid2","type":"key","code":"ESC","modifiers":[]}' "ok"
ipc_check "mouse_move"     '{"id":"hid3","type":"mouse_move","dx":100,"dy":0}' "ok"
ipc_check "mouse_move back" '{"id":"hid4","type":"mouse_move","dx":-100,"dy":0}' "ok"
ipc_check "mouse_click"    '{"id":"hid5","type":"mouse_click","button":"left"}' "ok"
ipc_check "media vol_up"   '{"id":"hid6","type":"media_key","key":"volume_up"}' "ok"
ipc_check "media vol_down" '{"id":"hid7","type":"media_key","key":"volume_down"}' "ok"
ipc_check "release"        '{"id":"hid8","type":"release"}' "ok"
ipc_check "reset"          '{"id":"hid9","type":"reset"}' "ok"

# ── Latency stats ─────────────────────────────────
hdr "Latency summary"

if [ "${#LATENCIES[@]}" -gt 0 ]; then
    SUM=0; MIN=99999; MAX=0
    for ms in "${LATENCIES[@]}"; do
        SUM=$((SUM + ms))
        [ "$ms" -lt "$MIN" ] && MIN=$ms
        [ "$ms" -gt "$MAX" ] && MAX=$ms
    done
    AVG=$((SUM / ${#LATENCIES[@]}))
    dim "Samples: ${#LATENCIES[@]}  min: ${MIN}ms  avg: ${AVG}ms  max: ${MAX}ms"

    if [ "$AVG" -lt 100 ]; then
        pass "Average latency ${AVG}ms (good)"
    elif [ "$AVG" -lt 500 ]; then
        pass "Average latency ${AVG}ms (acceptable — SSH path)"
    else
        fail "Average latency ${AVG}ms (slow — check bridge mode)"
    fi
fi

# ── Final status ──────────────────────────────────
FINAL_STATUS=$(ipc '{"id":"final","type":"status"}')
dim "Final status: $FINAL_STATUS"

echo ""
echo "═══════════════════════════════════════════"
echo -e "  ${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}  ${YELLOW}Skipped: $SKIPPED${NC}"

if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}✅ All tests passed — safe to activate${NC}"
else
    echo -e "  ${RED}❌ $FAILED failure(s) — investigate before activating${NC}"
fi
echo "═══════════════════════════════════════════"

exit "$FAILED"
