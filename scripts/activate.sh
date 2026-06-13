#!/bin/bash
set -e

# ── Usage ─────────────────────────────────────────
# Run after deploy.sh + manual testing:
#   ./scripts/activate.sh [host] [user]
#
# Swaps ~/pi-agent-new into /usr/local/bin/pi-agent
# and restarts the systemd service.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PI_HOST="${PI_HOST:-${1:-169.254.206.2}}"
PI_USER="${PI_USER:-${2:-pi}}"

GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
info() { echo -e "${BLUE}ℹ  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }

echo "═══════════════════════════════════════"
echo "  ZeroBridge — Activate"
echo "  Host: $PI_USER@$PI_HOST"
echo "═══════════════════════════════════════"
echo ""

ssh "$PI_USER@$PI_HOST" "sudo bash -s" << 'REMOTE'
set -e

[ -f ~/pi-agent-new ] || { echo "❌ ~/pi-agent-new not found — run deploy.sh first"; exit 1; }

# Install binary
mv ~/pi-agent-new /usr/local/bin/pi-agent
chmod +x /usr/local/bin/pi-agent
echo "✅ Binary installed"

# Install scripts
[ -f ~/multi-hid-setup.sh ] && {
    mv ~/multi-hid-setup.sh /usr/local/bin/multi-hid-setup.sh
    chmod +x /usr/local/bin/multi-hid-setup.sh
    echo "✅ multi-hid-setup.sh installed"
}

# Install service files (patch {{USER}} placeholder)
ZB_USER="$(logname 2>/dev/null || echo pi)"
[ -f ~/pi-agent.service ] && {
    sed "s/{{USER}}/$ZB_USER/g" ~/pi-agent.service > /etc/systemd/system/pi-agent.service
    rm ~/pi-agent.service
    echo "✅ pi-agent.service installed"
}
[ -f ~/mac-hid-setup.service ] && {
    cp ~/mac-hid-setup.service /etc/systemd/system/mac-hid-setup.service
    rm ~/mac-hid-setup.service
    echo "✅ mac-hid-setup.service installed"
}

# /etc/hosts entry
grep -q "mac.hid" /etc/hosts || {
    echo "169.254.206.1   mac.hid" >> /etc/hosts
    echo "✅ mac.hid added to /etc/hosts"
}

# Reload and restart pi-agent only (never touch mac-hid-setup)
systemctl daemon-reload
systemctl enable pi-agent.service
systemctl restart pi-agent
sleep 1
systemctl is-active pi-agent && echo "✅ pi-agent running" || echo "❌ pi-agent failed to start"
REMOTE

echo ""
echo "═══════════════════════════════════════"
ok "Activation complete"
echo ""
echo "Verify:"
echo "  ssh $PI_USER@$PI_HOST 'journalctl -u pi-agent -n 30'"
echo "  ssh $PI_USER@$PI_HOST 'echo {\"id\":\"1\",\"type\":\"ping\"} | nc -q 1 -U /tmp/zerobridge.sock'"
echo "═══════════════════════════════════════"
