#!/bin/bash
# zb-ctl — ZeroBridge control tool (run on Mac)
# Usage: zb-ctl <command>

PI_HOST="${PI_HOST:-169.254.206.2}"
PI_USER="${PI_USER:-vasugarg}"
ZB_PORT="${ZB_PORT:-8443}"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
info() { echo -e "${BLUE}ℹ  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }

cmd="${1:-help}"

case "$cmd" in

# ── Setup code ────────────────────────────────────────────────────────────────

setup-code)
    info "Generating setup code on Pi..."
    RESULT=$(ssh "$PI_USER@$PI_HOST" \
        "curl -sk -X POST https://localhost:$ZB_PORT/admin/setup-code" 2>/dev/null)

    CODE=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['code'])" 2>/dev/null)

    if [ -z "$CODE" ]; then
        fail "Could not get setup code. Is go-server running?\n  ssh $PI_USER@$PI_HOST journalctl -u go-server -n 5 --no-pager"
    fi

    echo ""
    echo -e "${BOLD}  ZeroBridge Setup Code${NC}"
    echo "  ─────────────────────"
    echo -e "  ${BOLD}${GREEN}  $CODE  ${NC}"
    echo "  ─────────────────────"
    echo "  Valid for 5 minutes"
    echo ""
    echo "  On iPhone: open https://$PI_HOST:$ZB_PORT"
    echo "  Enter this code when prompted."
    echo ""

    # Show QR if qrencode is available
    if command -v qrencode &>/dev/null; then
        echo "  Scan to open the app:"
        qrencode -t ANSI "https://$PI_HOST:$ZB_PORT" 2>/dev/null
    fi
    ;;

# ── Status ────────────────────────────────────────────────────────────────────

status)
    info "go-server status:"
    ssh "$PI_USER@$PI_HOST" "systemctl is-active go-server && journalctl -u go-server -n 5 --no-pager"
    echo ""
    info "pi-agent status:"
    ssh "$PI_USER@$PI_HOST" "systemctl is-active pi-agent && journalctl -u pi-agent -n 5 --no-pager"
    ;;

# ── Logs ──────────────────────────────────────────────────────────────────────

log|logs)
    TARGET="${2:-go-server}"
    ssh "$PI_USER@$PI_HOST" "journalctl -u $TARGET -f"
    ;;

# ── Restart ───────────────────────────────────────────────────────────────────

restart)
    TARGET="${2:-go-server}"
    info "Restarting $TARGET..."
    ssh "$PI_USER@$PI_HOST" "sudo systemctl restart $TARGET"
    sleep 1
    ssh "$PI_USER@$PI_HOST" "systemctl is-active $TARGET" && ok "$TARGET restarted" || fail "$TARGET failed to start"
    ;;

# ── Deploy go-server ──────────────────────────────────────────────────────────

deploy-go)
    REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    REPO_DIR="$(cd "$(dirname "$REAL_SCRIPT")/.." && pwd)"
    GO_SRC="$REPO_DIR/go-server"

    info "Building go-server for Pi Zero (arm6)..."
    GOOS=linux GOARCH=arm GOARM=6 go build -C "$GO_SRC" -o go-server . || fail "Build failed"
    ok "Build complete"

    info "Copying binary to Pi..."
    scp "$GO_SRC/go-server" "$PI_USER@$PI_HOST:~/go-server-new" || fail "scp failed"

    info "Installing + restarting on Pi..."
    ssh "$PI_USER@$PI_HOST" "
        sudo cp /usr/local/bin/go-server /usr/local/bin/go-server.bak 2>/dev/null || true
        sudo mv ~/go-server-new /usr/local/bin/go-server
        sudo systemctl restart go-server
        sleep 1
    " || fail "Remote install failed"
    ok "Deployed. Logs:"
    echo ""
    ssh "$PI_USER@$PI_HOST" "journalctl -u go-server -n 15 --no-pager"
    ;;

# ── Regen certs ───────────────────────────────────────────────────────────────

regen-certs)
    warn "This will regenerate TLS certificates. iPhone will need to reinstall the CA cert."
    read -p "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }

    REAL_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    REPO_DIR="$(cd "$(dirname "$REAL_SCRIPT")/.." && pwd)"
    scp "$REPO_DIR/scripts/gen-certs.sh" "$PI_USER@$PI_HOST:~/gen-certs.sh"
    ssh "$PI_USER@$PI_HOST" "sudo bash ~/gen-certs.sh && sudo systemctl restart go-server"
    ok "Certs regenerated. Reinstall CA on iPhone:"
    echo "  https://$PI_HOST:$ZB_PORT/ca.crt"
    ;;

# ── Help ──────────────────────────────────────────────────────────────────────

help|--help|-h|*)
    echo ""
    echo -e "${BOLD}zb-ctl${NC} — ZeroBridge control tool"
    echo ""
    echo "Commands:"
    echo "  setup-code          Generate a 6-digit iPhone registration code (valid 5 min)"
    echo "  deploy-go           Build go-server, copy with backup, restart, show logs"
    echo "  status              Show go-server + pi-agent status"
    echo "  log [service]       Tail logs (default: go-server)"
    echo "  restart [service]   Restart a service (default: go-server)"
    echo "  regen-certs         Regenerate TLS certificates"
    echo ""
    echo "Environment:"
    echo "  PI_HOST   Pi IP or hostname  (default: 169.254.206.2)"
    echo "  PI_USER   Pi SSH username    (default: vasugarg)"
    echo "  ZB_PORT   go-server port     (default: 8443)"
    echo ""
    echo "Examples:"
    echo "  zb-ctl setup-code"
    echo "  PI_HOST=192.168.0.123 zb-ctl setup-code"
    echo "  zb-ctl log pi-agent"
    echo "  zb-ctl restart go-server"
    echo ""
    ;;
esac
