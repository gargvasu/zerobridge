#!/bin/bash
set -e

# ── Usage ─────────────────────────────────────────
# ./scripts/deploy.sh [host] [user]
# 
# Environment variables:
#   PI_HOST  — Pi Zero IP or hostname (default: 169.254.206.2)
#   PI_USER  — Pi Zero username       (default: pi)
#
# Examples:
#   ./scripts/deploy.sh
#   ./scripts/deploy.sh 192.168.0.123
#   PI_HOST=raspberrypizero.local PI_USER=vasugarg ./scripts/deploy.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PI_HOST="${PI_HOST:-${1:-169.254.206.2}}"
PI_USER="${PI_USER:-${2:-pi}}"

GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
info() { echo -e "${BLUE}ℹ  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }

BINARY="$REPO_DIR/pi-agent/target/arm-unknown-linux-gnueabihf/release/pi-agent"

echo "═══════════════════════════════════════"
echo "  ZeroBridge — Deploy"
echo "  Host: $PI_USER@$PI_HOST"
echo "═══════════════════════════════════════"
echo ""

# ── Check binary exists ───────────────────────────
[ -f "$BINARY" ] || fail "Binary not found — run ./scripts/build.sh first"

# ── Copy binary ───────────────────────────────────
info "Copying pi-agent to $PI_USER@$PI_HOST..."
scp "$BINARY" "$PI_USER@$PI_HOST:~/pi-agent-new"
ok "Binary copied"

# ── Copy service files ────────────────────────────
info "Copying systemd service files..."
scp "$REPO_DIR/systemd/pi-agent.service" \
    "$PI_USER@$PI_HOST:~/pi-agent.service"
scp "$REPO_DIR/systemd/multi-hid-setup.service" \
    "$PI_USER@$PI_HOST:~/multi-hid-setup.service"
ok "Service files copied"

# ── Copy scripts ──────────────────────────────────
info "Copying scripts..."
scp "$REPO_DIR/scripts/multi-hid-setup.sh" \
    "$PI_USER@$PI_HOST:~/multi-hid-setup.sh"
ok "Scripts copied"

# ── Copy config example ───────────────────────────
scp "$REPO_DIR/config/config.toml.example" \
    "$PI_USER@$PI_HOST:~/config.toml.example"

# ── Install remotely ──────────────────────────────
info "Installing on Pi Zero..."
ssh "$PI_USER@$PI_HOST" "sudo bash -s" << REMOTE
set -e

# Binary
mv ~/pi-agent-new /usr/local/bin/pi-agent
chmod +x /usr/local/bin/pi-agent

# HID setup script
mv ~/multi-hid-setup.sh /usr/local/bin/multi-hid-setup.sh
chmod +x /usr/local/bin/multi-hid-setup.sh

# Service files
mv ~/pi-agent.service /etc/systemd/system/pi-agent.service
mv ~/multi-hid-setup.service /etc/systemd/system/multi-hid-setup.service

# Config
CONFIG_DIR="/home/$PI_USER/.config/zerobridge"
mkdir -p "\$CONFIG_DIR"
if [ ! -f "\$CONFIG_DIR/config.toml" ]; then
    cp ~/config.toml.example "\$CONFIG_DIR/config.toml"
    echo "⚠️  Edit \$CONFIG_DIR/config.toml before starting"
fi

# /etc/hosts
grep -q "hid.macmini" /etc/hosts || \
    echo "169.254.206.1   hid.macmini" >> /etc/hosts

# Systemd
systemctl daemon-reload
systemctl enable multi-hid-setup.service
systemctl enable pi-agent.service

# Restart if already running otherwise start
if systemctl is-active --quiet pi-agent; then
    systemctl restart pi-agent
    echo "✅ pi-agent restarted"
else
    systemctl start pi-agent || true
    echo "✅ pi-agent started"
fi
REMOTE

ok "Deploy complete!"
echo ""
echo "═══════════════════════════════════════"
echo "Check status:"
echo "  ssh $PI_USER@$PI_HOST 'systemctl status pi-agent'"
echo "  ssh $PI_USER@$PI_HOST 'journalctl -u pi-agent -f'"
echo ""
echo "Test socket:"
echo "  ssh $PI_USER@$PI_HOST 'echo {\"id\":\"1\",\"type\":\"ping\"} | nc -q 1 -U /tmp/zerobridge.sock'"
echo "═══════════════════════════════════════"