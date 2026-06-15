#!/bin/bash
# ── Usage ─────────────────────────────────────────
# Run ON the Mac to manage zb-agent (production) or zb-agent-dev (testing).
#
#   ./scripts/zb-agent-ctl.sh start          # start production agent via launchd
#   ./scripts/zb-agent-ctl.sh stop           # stop production agent
#   ./scripts/zb-agent-ctl.sh restart        # restart production agent
#   ./scripts/zb-agent-ctl.sh status         # show launchd status + process info
#   ./scripts/zb-agent-ctl.sh log            # tail live log
#   ./scripts/zb-agent-ctl.sh install        # install plist + register with launchd
#   ./scripts/zb-agent-ctl.sh uninstall      # unload + remove plist
#
#   ./scripts/zb-agent-ctl.sh dev            # stop prod, run dev binary in foreground
#   ./scripts/zb-agent-ctl.sh dev-bg         # stop prod, run dev binary in background
#   ./scripts/zb-agent-ctl.sh dev-stop       # stop dev binary, restart prod
#   ./scripts/zb-agent-ctl.sh deploy-dev     # copy ./mac-agent/zb-agent → /usr/local/bin/zb-agent-dev

LABEL="com.zerobridge.zb-agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PROD_BIN="$HOME/bin/zb-agent"
DEV_BIN="$HOME/bin/zb-agent-dev"
PORT=8082
BIND="169.254.206.1"
LOG="/tmp/zb-agent.log"
DEV_LOG="/tmp/zb-agent-dev.log"
DEV_PID_FILE="/tmp/zb-agent-dev.pid"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_SRC="$REPO_DIR/mac-agent/$LABEL.plist"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; GRAY='\033[0;90m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; }
info() { echo -e "${BLUE}ℹ  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠  $1${NC}"; }
dim()  { echo -e "${GRAY}   $1${NC}"; }

# ── Helpers ───────────────────────────────────────

launchd_loaded() {
    launchctl list "$LABEL" &>/dev/null
}

# Kill process by pid, don't block
kill_prod() {
    local pid
    pid=$(prod_pid)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
}

wait_dead() {
    local name="$1" check_fn="$2" max=10 i=0
    while eval "$check_fn" &>/dev/null && [ $i -lt $max ]; do
        sleep 0.3; i=$((i+1))
    done
}

wait_alive() {
    local max="${1:-10}" i=0
    while [ -z "$(prod_pid)" ] && [ $i -lt $max ]; do
        sleep 0.3; i=$((i+1))
    done
}

prod_pid() {
    pgrep -f "$PROD_BIN serve" 2>/dev/null | head -1
}

dev_pid() {
    if [ -f "$DEV_PID_FILE" ]; then
        local pid
        pid=$(cat "$DEV_PID_FILE")
        kill -0 "$pid" 2>/dev/null && echo "$pid" || rm -f "$DEV_PID_FILE"
    fi
}

probe_ws() {
    # Returns "up" if WebSocket port is open, "down" otherwise
    nc -z -w1 "$BIND" "$PORT" 2>/dev/null && echo "up" || echo "down"
}

ensure_plist_installed() {
    if [ ! -f "$PLIST" ]; then
        fail "Plist not installed at $PLIST"
        info "Run: $0 install"
        exit 1
    fi
}

# ── Commands ──────────────────────────────────────

cmd_install() {
    [ -f "$PLIST_SRC" ] || { fail "Source plist not found: $PLIST_SRC"; exit 1; }
    [ -f "$PROD_BIN"  ] || { warn "Binary not found at $PROD_BIN — install it first"; }

    # Unload first if already registered (ignore errors)
    launchd_loaded && launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null; sleep 0.3

    cp "$PLIST_SRC" "$PLIST"
    ok "Plist copied to $PLIST"

    launchctl bootstrap "gui/$(id -u)" "$PLIST" &
    local boot_pid=$!
    sleep 2
    kill $boot_pid 2>/dev/null; wait $boot_pid 2>/dev/null

    wait_alive 15
    local pid
    pid=$(prod_pid)
    if [ -n "$pid" ]; then
        ok "zb-agent registered and running (pid $pid)"
        dim "Log: $LOG"
    else
        warn "Registered with launchd but process not yet up"
        dim "Check: $0 status"
        dim "Log:   $0 log"
    fi
}

cmd_uninstall() {
    launchd_loaded && {
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
        sleep 0.5
        ok "Unloaded from launchd"
    }
    kill_prod
    rm -f "$PLIST"
    ok "Plist removed"
}

cmd_start() {
    ensure_plist_installed

    local pid
    pid=$(prod_pid)
    if [ -n "$pid" ]; then
        ok "Already running (pid $pid)"
        return
    fi

    info "Starting zb-agent..."

    if launchd_loaded; then
        # Already registered — just launch the process directly (non-blocking)
        launchctl kickstart "gui/$(id -u)/$LABEL" &>/dev/null &
        disown
    else
        launchctl bootstrap "gui/$(id -u)" "$PLIST" &>/dev/null &
        disown
    fi

    wait_alive 15
    pid=$(prod_pid)
    if [ -n "$pid" ]; then
        ok "zb-agent started (pid $pid, port $PORT)"
        dim "WS: $(probe_ws)"
        dim "Log: $LOG"
    else
        fail "zb-agent did not start within 4.5s"
        dim "Check: tail -20 $LOG"
        tail -10 "$LOG" 2>/dev/null | sed 's/^/  /'
    fi
}

cmd_stop() {
    info "Stopping zb-agent..."
    # Signal launchd to not restart it, then kill the process
    launchd_loaded && launchctl kill TERM "gui/$(id -u)/$LABEL" 2>/dev/null; sleep 0.3
    kill_prod
    # Give it a moment to die cleanly
    wait_dead "zb-agent" "prod_pid"
    local pid
    pid=$(prod_pid)
    [ -z "$pid" ] && ok "zb-agent stopped" || warn "Process $pid still alive — may take a moment (launchd will restart it)"
    dim "launchd will restart it automatically. Use 'uninstall' to remove permanently."
}

cmd_restart() {
    ensure_plist_installed
    info "Restarting zb-agent..."

    # Kill process — launchd KeepAlive will relaunch it automatically
    launchd_loaded && launchctl kill TERM "gui/$(id -u)/$LABEL" 2>/dev/null
    kill_prod
    sleep 0.5

    wait_alive 15
    local pid
    pid=$(prod_pid)
    if [ -n "$pid" ]; then
        ok "zb-agent restarted (pid $pid)"
        dim "WS: $(probe_ws)"
    else
        fail "zb-agent did not restart — check $LOG"
        tail -10 "$LOG" 2>/dev/null | sed 's/^/  /'
    fi
}

cmd_status() {
    echo "═══════════════════════════════════════"
    echo "  zb-agent status"
    echo "═══════════════════════════════════════"

    # Plist
    [ -f "$PLIST" ] && dim "plist: installed" || warn "plist: NOT installed (run: $0 install)"

    # launchd registration
    if launchd_loaded; then
        local exit_code
        exit_code=$(launchctl list "$LABEL" 2>/dev/null | awk '/"LastExitStatus"/{gsub(/[;,]/, "", $NF); print $NF}')
        ok "launchd: registered (LastExitStatus=${exit_code:-?})"
    else
        warn "launchd: not registered"
    fi

    # prod process
    local ppid
    ppid=$(prod_pid)
    if [ -n "$ppid" ]; then
        ok "prod: pid $ppid  port $PORT  WS=$(probe_ws)"
    else
        fail "prod: not running"
    fi

    # dev process
    local dpid
    dpid=$(dev_pid)
    if [ -n "$dpid" ]; then
        ok "dev:  pid $dpid  port $((PORT+1))"
        dim "Log: $DEV_LOG"
    else
        dim "dev:  not running"
    fi

    # Binaries
    echo ""
    [ -f "$PROD_BIN" ] \
        && dim "prod bin: $PROD_BIN  ($(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$PROD_BIN"))" \
        || warn "prod bin: NOT found at $PROD_BIN"
    [ -f "$DEV_BIN" ] \
        && dim "dev  bin: $DEV_BIN  ($(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$DEV_BIN"))" \
        || dim "dev  bin: not installed"

    echo "═══════════════════════════════════════"
}

cmd_log() {
    echo "Tailing $LOG (Ctrl-C to stop)"
    tail -f "$LOG"
}

cmd_dev() {
    [ -f "$DEV_BIN" ] || { fail "Dev binary not found: $DEV_BIN"; info "Run: $0 deploy-dev"; exit 1; }

    info "Stopping production agent (launchd will NOT restart — KeepAlive only triggers on crash/exit)..."
    launchd_loaded && launchctl kill TERM "gui/$(id -u)/$LABEL" 2>/dev/null
    kill_prod; sleep 0.5

    info "Starting dev agent in foreground on port $((PORT+1))..."
    dim "Ctrl-C to stop. Run '$0 dev-stop' afterwards to restore prod."
    echo ""
    "$DEV_BIN" serve --port "$((PORT+1))" --bind "$BIND" 2>&1 | tee "$DEV_LOG"
}

cmd_dev_bg() {
    [ -f "$DEV_BIN" ] || { fail "Dev binary not found: $DEV_BIN"; info "Run: $0 deploy-dev"; exit 1; }

    local dpid
    dpid=$(dev_pid)
    [ -n "$dpid" ] && { fail "Dev agent already running (pid $dpid) — run '$0 dev-stop' first"; exit 1; }

    info "Stopping production agent..."
    launchd_loaded && launchctl kill TERM "gui/$(id -u)/$LABEL" 2>/dev/null
    kill_prod; sleep 0.5

    info "Starting dev agent in background on port $((PORT+1))..."
    "$DEV_BIN" serve --port "$((PORT+1))" --bind "$BIND" >> "$DEV_LOG" 2>&1 &
    echo $! > "$DEV_PID_FILE"
    sleep 1
    dpid=$(dev_pid)
    if [ -n "$dpid" ]; then
        ok "Dev agent started (pid $dpid, port $((PORT+1)))"
        dim "Log: tail -f $DEV_LOG"
        dim "Stop: $0 dev-stop"
    else
        fail "Dev agent did not start — check $DEV_LOG"
        tail -5 "$DEV_LOG" 2>/dev/null | sed 's/^/  /'
    fi
}

cmd_dev_stop() {
    local dpid
    dpid=$(dev_pid)
    if [ -n "$dpid" ]; then
        kill "$dpid" 2>/dev/null
        sleep 0.3
        ok "Dev agent stopped (pid $dpid)"
        rm -f "$DEV_PID_FILE"
    else
        info "Dev agent not running"
    fi

    info "Restoring production agent..."
    # launchd KeepAlive should already be trying to restart it
    # If not registered yet, bootstrap it
    if ! launchd_loaded; then
        ensure_plist_installed
        launchctl bootstrap "gui/$(id -u)" "$PLIST" &>/dev/null &
        disown
    fi
    wait_alive 15
    local ppid
    ppid=$(prod_pid)
    [ -n "$ppid" ] && ok "Production agent restored (pid $ppid)" || fail "Prod agent did not start — check $LOG"
}

cmd_deploy_dev() {
    local SRC="$REPO_DIR/mac-agent/zb-agent"
    [ -f "$SRC" ] || { fail "Dev binary not found at $SRC"; info "Build: cd mac-agent && swift build -c release"; exit 1; }
    info "Copying $SRC → $DEV_BIN ..."
    cp "$SRC" "$DEV_BIN"
    chmod +x "$DEV_BIN"
    ok "Deployed dev binary to $DEV_BIN"
    dim "$(file "$DEV_BIN")"
    dim "Test: $0 dev     (foreground, port $((PORT+1)))"
    dim "   or: $0 dev-bg (background, port $((PORT+1)))"
}

# ── Dispatch ──────────────────────────────────────

CMD="${1:-status}"
case "$CMD" in
    install)     cmd_install ;;
    uninstall)   cmd_uninstall ;;
    start)       cmd_start ;;
    stop)        cmd_stop ;;
    restart)     cmd_restart ;;
    status)      cmd_status ;;
    log)         cmd_log ;;
    dev)         cmd_dev ;;
    dev-bg)      cmd_dev_bg ;;
    dev-stop)    cmd_dev_stop ;;
    deploy-dev)  cmd_deploy_dev ;;
    *)
        echo "Usage: $0 <command>"
        echo ""
        echo "  install      Install plist + register with launchd (run once)"
        echo "  uninstall    Unload from launchd + remove plist"
        echo "  start        Start production zb-agent (port $PORT)"
        echo "  stop         Stop production zb-agent (launchd will restart on next login)"
        echo "  restart      Restart production zb-agent"
        echo "  status       Show running status of prod + dev agents"
        echo "  log          Tail production log ($LOG)"
        echo ""
        echo "  dev          Stop prod, run dev binary in foreground (port $((PORT+1)))"
        echo "  dev-bg       Stop prod, run dev binary in background (port $((PORT+1)))"
        echo "  dev-stop     Stop dev binary, restore prod via launchd"
        echo "  deploy-dev   Copy mac-agent/zb-agent → $DEV_BIN"
        exit 1
        ;;
esac
