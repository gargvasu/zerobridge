#!/bin/bash
set -e

# ── Usage ─────────────────────────────────────────
# ./scripts/activate.sh [component...] [--host HOST] [--user USER]
#
# Components:  pi  go  services  (default: all staged)
#
# Examples:
#   ./scripts/activate.sh            # activate everything staged
#   ./scripts/activate.sh pi         # swap pi-agent only
#   ./scripts/activate.sh go         # swap go-server only
#   ./scripts/activate.sh pi go      # both binaries
#   ./scripts/activate.sh services   # reinstall service files only
#   ./scripts/activate.sh go --host 192.168.1.50
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

DO_PI=false; DO_GO=false; DO_SERVICES=false
EXPLICIT=false
PI_HOST="${PI_HOST:-169.254.206.2}"
PI_USER="${PI_USER:-vasugarg}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        pi)       DO_PI=true;       EXPLICIT=true; shift ;;
        go)       DO_GO=true;       EXPLICIT=true; shift ;;
        services) DO_SERVICES=true; EXPLICIT=true; shift ;;
        --host)   PI_HOST="$2"; shift 2 ;;
        --user)   PI_USER="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [pi] [go] [services] [--host HOST] [--user USER]"
            echo "       $0          # activate everything staged"
            echo "       $0 pi       # swap pi-agent only"
            echo "       $0 go       # swap go-server only"
            echo "       $0 services # reinstall service files only"
            exit 0 ;;
        *) fail "Unknown argument: $1  (valid: pi go services --host --user)" ;;
    esac
done

# Default: activate everything
if [ "$EXPLICIT" = false ]; then
    DO_PI=true; DO_GO=true; DO_SERVICES=true
fi

echo "═══════════════════════════════════════"
echo "  ZeroBridge — Activate"
echo "  Host: $PI_USER@$PI_HOST"
PARTS=""
[ "$DO_PI" = true ]       && PARTS="$PARTS pi-agent"
[ "$DO_GO" = true ]       && PARTS="$PARTS go-server"
[ "$DO_SERVICES" = true ] && PARTS="$PARTS services"
echo "  Components:${PARTS}"
echo "═══════════════════════════════════════"
echo ""

# Pass component flags into the remote script via env vars
DO_PI_R="$DO_PI"
DO_GO_R="$DO_GO"
DO_SERVICES_R="$DO_SERVICES"

ssh "$PI_USER@$PI_HOST" "sudo bash -s" << REMOTE
set -e
USER_HOME="/home/$PI_USER"

DO_PI="$DO_PI_R"
DO_GO="$DO_GO_R"
DO_SERVICES="$DO_SERVICES_R"

# ── pi-agent ──────────────────────────────────────

if [ "\$DO_PI" = true ]; then
    [ -f "\$USER_HOME/pi-agent-new" ] || { echo "❌ ~/pi-agent-new not found — run deploy.sh pi first"; exit 1; }
    mv "\$USER_HOME/pi-agent-new" /usr/local/bin/pi-agent
    chmod +x /usr/local/bin/pi-agent
    echo "✅ pi-agent binary installed"
fi

# ── go-server ─────────────────────────────────────

if [ "\$DO_GO" = true ]; then
    [ -f "\$USER_HOME/go-server-new" ] || { echo "❌ ~/go-server-new not found — run deploy.sh go first"; exit 1; }
    mv "\$USER_HOME/go-server-new" /usr/local/bin/go-server
    chmod +x /usr/local/bin/go-server
    echo "✅ go-server binary installed"
fi

# ── Service files ─────────────────────────────────
# Never touch mac-hid-setup.service — controls USB gadget kernel modules

if [ "\$DO_SERVICES" = true ] || [ "\$DO_PI" = true ]; then
    if [ -f "\$USER_HOME/pi-agent.service" ]; then
        sed "s/{{USER}}/$PI_USER/g" "\$USER_HOME/pi-agent.service" > /etc/systemd/system/pi-agent.service
        rm "\$USER_HOME/pi-agent.service"
        echo "✅ pi-agent.service installed"
    fi
fi

if [ "\$DO_SERVICES" = true ] || [ "\$DO_GO" = true ]; then
    if [ -f "\$USER_HOME/go-server.service" ]; then
        HOSTNAME=\$(hostname)
        sed "s/{{USER}}/$PI_USER/g; s/{{HOSTNAME}}/\$HOSTNAME/g" "\$USER_HOME/go-server.service" > /etc/systemd/system/go-server.service
        rm "\$USER_HOME/go-server.service"
        echo "✅ go-server.service installed (rpid=\$HOSTNAME)"
    fi
fi

# ── /etc/hosts ────────────────────────────────────

grep -q "mac.hid" /etc/hosts || {
    echo "169.254.206.1   mac.hid" >> /etc/hosts
    echo "✅ mac.hid added to /etc/hosts"
}

# ── Reload & restart ──────────────────────────────

systemctl daemon-reload

if [ "\$DO_PI" = true ]; then
    systemctl enable pi-agent.service
    systemctl restart pi-agent
    sleep 1
    systemctl is-active pi-agent && echo "✅ pi-agent running" || echo "❌ pi-agent failed to start"
fi

if [ "\$DO_GO" = true ]; then
    if [ -f /etc/systemd/system/go-server.service ]; then
        systemctl enable go-server.service
        systemctl restart go-server
        sleep 1
        systemctl is-active go-server && echo "✅ go-server running" || echo "❌ go-server failed to start"
    fi
fi
REMOTE

echo ""
echo "═══════════════════════════════════════"
ok "Activation complete"
echo ""
echo "Verify:"
[ "$DO_PI" = true ] && echo "  ssh $PI_USER@$PI_HOST 'journalctl -u pi-agent -n 20 --no-pager'"
[ "$DO_GO" = true ] && echo "  ssh $PI_USER@$PI_HOST 'journalctl -u go-server -n 20 --no-pager'"
[ "$DO_GO" = true ] && echo "  open http://$PI_HOST:8080"
echo "═══════════════════════════════════════"
