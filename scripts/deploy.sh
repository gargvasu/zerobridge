#!/bin/bash
set -e

# ── Usage ─────────────────────────────────────────
# ./scripts/deploy.sh [host] [user]
#
# Environment variables:
#   PI_HOST  — Pi Zero IP or hostname (default: 169.254.206.2)
#   PI_USER  — Pi Zero username       (default: pi)
#
# What this does:
#   1. Copies pi-agent binary as ~/pi-agent-new  (does NOT restart anything)
#   2. Copies service files and scripts
#   3. Leaves systemd pi-agent service untouched
#
# After verifying with the test daemon, run:
#   ./scripts/activate.sh [host] [user]

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
echo "  ZeroBridge — Deploy (safe, no restart)"
echo "  Host: $PI_USER@$PI_HOST"
echo "═══════════════════════════════════════"
echo ""

[ -f "$BINARY" ] || fail "Binary not found — run ./scripts/build.sh first"

info "Copying pi-agent binary as pi-agent-new..."
scp "$BINARY" "$PI_USER@$PI_HOST:~/pi-agent-new"
ok "Binary staged at ~/pi-agent-new (systemd service untouched)"

info "Copying service files..."
scp "$REPO_DIR/systemd/pi-agent.service"        "$PI_USER@$PI_HOST:~/pi-agent.service"
scp "$REPO_DIR/systemd/mac-hid-setup.service"   "$PI_USER@$PI_HOST:~/mac-hid-setup.service"
ok "Service files staged"

info "Copying scripts..."
scp "$REPO_DIR/scripts/multi-hid-setup.sh" "$PI_USER@$PI_HOST:~/multi-hid-setup.sh"
scp "$REPO_DIR/config/config.toml.example" "$PI_USER@$PI_HOST:~/config.toml.example"
ok "Scripts and config example staged"

echo ""
echo "═══════════════════════════════════════"
ok "Deploy staged — systemd pi-agent NOT restarted"
echo ""
echo "Next — test the new binary manually:"
echo ""
echo "  1. SSH in:"
echo "     ssh $PI_USER@$PI_HOST"
echo ""
echo "  2. Stop systemd daemon and run test daemon on a different socket:"
echo "     sudo systemctl stop pi-agent"
echo "     ZB_SOCK=/tmp/zb-test.sock ~/pi-agent-new"
echo ""
echo "  3. From another terminal, run tests:"
echo "     echo '{\"id\":\"1\",\"type\":\"ping\"}' | nc -q 1 -U /tmp/zb-test.sock"
echo ""
echo "  4. When satisfied, activate:"
echo "     ./scripts/activate.sh $PI_USER@$PI_HOST"
echo "═══════════════════════════════════════"
