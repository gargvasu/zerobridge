#!/bin/bash
set -e

# ── Usage ─────────────────────────────────────────
# Run ON the Pi Zero after cloning the repo:
#   sudo ./scripts/install.sh
#
# Or with custom user:
#   sudo ZB_USER=myuser ./scripts/install.sh

ZB_USER="${ZB_USER:-$(logname 2>/dev/null || echo pi)}"

GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
info() { echo -e "${BLUE}ℹ  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BINARY="$REPO_DIR/pi-agent/target/arm-unknown-linux-gnueabihf/release/pi-agent"
CONFIG_DIR="/home/$ZB_USER/.config/zerobridge"

[ "$EUID" -eq 0 ] || fail "Run as root: sudo ./scripts/install.sh"

echo "═══════════════════════════════════════"
echo "  ZeroBridge — Install on Pi Zero"
echo "  User: $ZB_USER"
echo "═══════════════════════════════════════"
echo ""

# ── Binary ────────────────────────────────────────
info "Installing pi-agent binary..."
[ -f "$BINARY" ] || fail "Binary not found at $BINARY
Build on your Mac first:
  ./scripts/build.sh
Then copy to Pi Zero:
  ./scripts/deploy.sh <pi-host> <pi-user>"

cp "$BINARY" /usr/local/bin/pi-agent
chmod +x /usr/local/bin/pi-agent
ok "pi-agent → /usr/local/bin/pi-agent"

# ── HID setup script ──────────────────────────────
info "Installing HID setup script..."
cp "$SCRIPT_DIR/multi-hid-setup.sh" /usr/local/bin/multi-hid-setup.sh
chmod +x /usr/local/bin/multi-hid-setup.sh
ok "multi-hid-setup.sh → /usr/local/bin/"

# ── Systemd ───────────────────────────────────────
info "Installing systemd services..."

# Patch service files with correct user
sed "s/{{USER}}/$ZB_USER/g" \
    "$REPO_DIR/systemd/pi-agent.service" \
    > /etc/systemd/system/pi-agent.service

sed "s/{{USER}}/$ZB_USER/g" \
    "$REPO_DIR/systemd/multi-hid-setup.service" \
    > /etc/systemd/system/multi-hid-setup.service

ok "Service files installed"

# ── Config ────────────────────────────────────────
info "Setting up config..."
mkdir -p "$CONFIG_DIR"
chown "$ZB_USER:$ZB_USER" "$CONFIG_DIR"

if [ ! -f "$CONFIG_DIR/config.toml" ]; then
    # Patch example config with correct user
    sed "s|/home/pi|/home/$ZB_USER|g" \
        "$REPO_DIR/config/config.toml.example" \
        > "$CONFIG_DIR/config.toml"
    chown "$ZB_USER:$ZB_USER" "$CONFIG_DIR/config.toml"
    warn "Config installed — edit $CONFIG_DIR/config.toml"
else
    info "Config exists — skipping"
fi

# ── /etc/hosts ────────────────────────────────────
info "Configuring /etc/hosts..."
grep -q "hid.macmini" /etc/hosts || \
    echo "169.254.206.1   hid.macmini" >> /etc/hosts
ok "hid.macmini → /etc/hosts"

# ── Enable services ───────────────────────────────
info "Enabling services..."
systemctl daemon-reload
systemctl enable multi-hid-setup.service
systemctl enable pi-agent.service
ok "Services enabled for boot"

# ── Start ─────────────────────────────────────────
info "Starting services..."
systemctl start multi-hid-setup.service || warn "HID setup failed — check /tmp/hid-setup.log"
sleep 2
systemctl start pi-agent || warn "pi-agent failed to start — check journalctl -u pi-agent"

echo ""
echo "═══════════════════════════════════════"
ok "ZeroBridge installed!"
echo ""
echo "Status:"
echo "  sudo systemctl status pi-agent"
echo "  sudo journalctl -u pi-agent -f"
echo ""
echo "Test:"
echo "  echo '{\"id\":\"1\",\"type\":\"ping\"}' | nc -q 1 -U /tmp/zerobridge.sock"
echo ""
echo "Config: $CONFIG_DIR/config.toml"
echo "═══════════════════════════════════════"