#!/bin/bash
set -e

# ── Usage ─────────────────────────────────────────
# ./scripts/deploy.sh [component...] [--host HOST] [--user USER]
#
# Components:  pi  go  services  config  (default: all)
#
# Examples:
#   ./scripts/deploy.sh                      # deploy everything
#   ./scripts/deploy.sh pi                   # pi-agent binary only
#   ./scripts/deploy.sh go                   # go-server binary only
#   ./scripts/deploy.sh pi go                # both binaries
#   ./scripts/deploy.sh services             # systemd service files only
#   ./scripts/deploy.sh pi --host 192.168.1.50 --user vasugarg
#
# Environment variables (alternative to --host / --user):
#   PI_HOST  — Pi Zero IP or hostname (default: 169.254.206.2)
#   PI_USER  — Pi Zero SSH username   (default: vasugarg)

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
info() { echo -e "${BLUE}ℹ  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }

# ── Parse args ────────────────────────────────────

DO_PI=false; DO_GO=false; DO_SERVICES=false; DO_CONFIG=false
EXPLICIT=false
PI_HOST="${PI_HOST:-169.254.206.2}"
PI_USER="${PI_USER:-vasugarg}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        pi)       DO_PI=true;       EXPLICIT=true; shift ;;
        go)       DO_GO=true;       EXPLICIT=true; shift ;;
        services) DO_SERVICES=true; EXPLICIT=true; shift ;;
        config)   DO_CONFIG=true;   EXPLICIT=true; shift ;;
        --host)   PI_HOST="$2"; shift 2 ;;
        --user)   PI_USER="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [pi] [go] [services] [config] [--host HOST] [--user USER]"
            echo "       $0           # deploy everything"
            echo "       $0 pi        # pi-agent binary only"
            echo "       $0 go        # go-server binary only"
            echo "       $0 pi go     # both binaries"
            echo "       $0 services  # systemd service files only"
            exit 0 ;;
        *) fail "Unknown argument: $1  (valid: pi go services config --host --user)" ;;
    esac
done

# Default: deploy everything
if [ "$EXPLICIT" = false ]; then
    DO_PI=true; DO_GO=true; DO_SERVICES=true; DO_CONFIG=true
fi

BINARY="$REPO_DIR/pi-agent/target/arm-unknown-linux-gnueabihf/release/pi-agent"
GO_BINARY="$REPO_DIR/go-server/go-server"

echo "═══════════════════════════════════════"
echo "  ZeroBridge — Deploy"
echo "  Host: $PI_USER@$PI_HOST"
PARTS=""
[ "$DO_PI" = true ]       && PARTS="$PARTS pi-agent"
[ "$DO_GO" = true ]       && PARTS="$PARTS go-server"
[ "$DO_SERVICES" = true ] && PARTS="$PARTS services"
[ "$DO_CONFIG" = true ]   && PARTS="$PARTS config"
echo "  Components:${PARTS}"
echo "═══════════════════════════════════════"
echo ""

# ── Stop affected daemons ─────────────────────────

STOP_CMDS=""
[ "$DO_PI" = true ] && STOP_CMDS="$STOP_CMDS pi-agent"
[ "$DO_GO" = true ] && STOP_CMDS="$STOP_CMDS go-server"

if [ -n "$STOP_CMDS" ]; then
    info "Stopping daemons on Pi:$STOP_CMDS ..."
    # shellcheck disable=SC2029
    ssh "$PI_USER@$PI_HOST" "sudo systemctl stop $STOP_CMDS 2>/dev/null || true; sudo killall $STOP_CMDS 2>/dev/null || true; sleep 0.3"
    ok "Stopped"
fi

# ── pi-agent binary ───────────────────────────────

if [ "$DO_PI" = true ]; then
    [ -f "$BINARY" ] || fail "pi-agent binary not found — run ./scripts/build.sh pi first"
    info "Staging pi-agent binary..."
    ssh "$PI_USER@$PI_HOST" "[ -f ~/pi-agent-new ] && mv ~/pi-agent-new ~/pi-agent-new.bak || true"
    scp "$BINARY" "$PI_USER@$PI_HOST:~/pi-agent-new"
    ok "pi-agent → ~/pi-agent-new  (previous → .bak)"
fi

# ── go-server binary ──────────────────────────────

if [ "$DO_GO" = true ]; then
    [ -f "$GO_BINARY" ] || fail "go-server binary not found — run ./scripts/build.sh go first"
    info "Staging go-server binary..."
    ssh "$PI_USER@$PI_HOST" "[ -f ~/go-server-new ] && mv ~/go-server-new ~/go-server-new.bak || true"
    scp "$GO_BINARY" "$PI_USER@$PI_HOST:~/go-server-new"
    ok "go-server → ~/go-server-new  (previous → .bak)"
fi

# ── Service files ─────────────────────────────────

if [ "$DO_SERVICES" = true ]; then
    info "Copying service files..."
    scp "$REPO_DIR/systemd/pi-agent.service"      "$PI_USER@$PI_HOST:~/pi-agent.service"
    scp "$REPO_DIR/systemd/mac-hid-setup.service" "$PI_USER@$PI_HOST:~/mac-hid-setup.service"
    scp "$REPO_DIR/systemd/go-server.service"     "$PI_USER@$PI_HOST:~/go-server.service"
    ok "Service files staged"
fi

# ── Config example ────────────────────────────────

if [ "$DO_CONFIG" = true ]; then
    info "Copying config example..."
    scp "$REPO_DIR/config/config.toml.example" "$PI_USER@$PI_HOST:~/config.toml.example"
    ok "Config example staged"
fi

# ── Summary ───────────────────────────────────────

echo ""
echo "═══════════════════════════════════════"
ok "Deploy staged — ready to activate"
echo ""
if [ "$DO_PI" = true ]; then
    echo "  Test pi-agent manually:"
    echo "    ssh $PI_USER@$PI_HOST"
    echo "    sudo ZB_SOCK=/tmp/zb-test.sock HOME=/home/$PI_USER ~/pi-agent-new"
    echo "    echo '{\"id\":\"1\",\"type\":\"ping\"}' | nc -q0 -U /tmp/zb-test.sock"
    echo ""
fi
echo "  Then activate:"
ACTIVATE_PARTS=""
[ "$DO_PI" = true ]       && ACTIVATE_PARTS="$ACTIVATE_PARTS pi"
[ "$DO_GO" = true ]       && ACTIVATE_PARTS="$ACTIVATE_PARTS go"
[ "$DO_SERVICES" = true ] && ACTIVATE_PARTS="$ACTIVATE_PARTS services"
echo "    ./scripts/activate.sh$ACTIVATE_PARTS"
echo "═══════════════════════════════════════"
