#!/bin/bash
# ── Usage ─────────────────────────────────────────
# Run ONCE on the Mac to configure the USB ethernet interface statically.
# Without this, macOS sometimes assigns a /32 netmask to the CDC-ECM
# interface, breaking connectivity to the Pi.
#
#   ./scripts/setup-mac.sh
#
# Safe to re-run — it checks before changing anything.

set -e

HOST_IP="${HOST_IP:-169.254.206.1}"
NETMASK="${NETMASK:-255.255.0.0}"

GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
info() { echo -e "${BLUE}ℹ  $1${NC}"; }

echo "═══════════════════════════════════════"
echo "  ZeroBridge — Mac Network Setup"
echo "═══════════════════════════════════════"
echo ""

# ── Find USB ethernet service ──────────────────────

info "Looking for USB CDC-ECM network service..."

# Try exact known name first, then fall back to pattern matching
SERVICE=$(networksetup -listallnetworkservices 2>/dev/null | grep -x "Pi Combo HID" | head -1)
if [ -z "$SERVICE" ]; then
    SERVICE=$(networksetup -listallnetworkservices 2>/dev/null \
        | grep -iE "pi.*combo|pi.*hid|gadget|rndis|ecm|usb.*eth|ethernet.*usb|usb.*100" \
        | head -1)
fi

if [ -z "$SERVICE" ]; then
    echo ""
    echo "  Could not auto-detect USB ethernet service."
    echo "  Available services:"
    networksetup -listallnetworkservices | grep -v "^An" | sed 's/^/    /'
    echo ""
    echo -n "  Enter the service name for the USB ethernet: "
    read -r SERVICE
fi

[ -z "$SERVICE" ] && fail "No service selected"
info "Using service: '$SERVICE'"

# ── Check current config ───────────────────────────

CURRENT=$(networksetup -getinfo "$SERVICE" 2>/dev/null | grep "^IP address:" | awk '{print $3}')
CURRENT_MASK=$(networksetup -getinfo "$SERVICE" 2>/dev/null | grep "^Subnet mask:" | awk '{print $3}')
CURRENT_METHOD=$(networksetup -getinfo "$SERVICE" 2>/dev/null | grep "^IPv4 Configured Using:" | cut -d: -f2 | xargs)

info "Current: method=$CURRENT_METHOD  ip=$CURRENT  mask=$CURRENT_MASK"

if [ "$CURRENT_METHOD" = "Manually" ] && [ "$CURRENT" = "$HOST_IP" ] && [ "$CURRENT_MASK" = "$NETMASK" ]; then
    ok "Already configured correctly — nothing to do"
    echo ""
    exit 0
fi

# ── Set static IP ──────────────────────────────────

info "Setting static IP $HOST_IP/$NETMASK on '$SERVICE'..."
networksetup -setmanual "$SERVICE" "$HOST_IP" "$NETMASK"
ok "Static IP set"

# ── Find interface name and verify ────────────────

sleep 1
IFACE=$(networksetup -listallhardwareports 2>/dev/null \
    | awk "/Hardware Port: $SERVICE/{found=1} found && /Device:/{print \$2; exit}")

if [ -n "$IFACE" ]; then
    ACTUAL_MASK=$(ifconfig "$IFACE" 2>/dev/null | awk '/inet /{print $4}')
    info "Interface: $IFACE  netmask: $ACTUAL_MASK"
    if [ "$ACTUAL_MASK" = "0xffff0000" ]; then
        ok "Netmask correct (0xffff0000 = 255.255.0.0)"
    else
        info "Netmask not yet applied — may need USB replug or interface bounce"
        info "Try: sudo ifconfig $IFACE inet $HOST_IP netmask $NETMASK"
    fi
else
    info "Could not determine interface name — verify with: ifconfig | grep $HOST_IP"
fi

# ── Add /etc/hosts entry ───────────────────────────

if ! grep -q "mac.hid" /etc/hosts 2>/dev/null; then
    info "Adding mac.hid → 127.0.0.1 to /etc/hosts..."
    echo "127.0.0.1  mac.hid" | sudo tee -a /etc/hosts > /dev/null
    ok "Added mac.hid to /etc/hosts"
else
    ok "mac.hid already in /etc/hosts"
fi

# ── Allow zb-agent through firewall ───────────────

ZB_AGENT="$HOME/bin/zb-agent"
if [ -f "$ZB_AGENT" ]; then
    info "Allowing zb-agent through firewall..."
    /usr/libexec/ApplicationFirewall/socketfilterfw --add "$ZB_AGENT" 2>/dev/null || true
    /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "$ZB_AGENT" 2>/dev/null || true
    ok "zb-agent firewall rule set"
else
    info "zb-agent not found at $ZB_AGENT — deploy the binary first"
fi

# ── Install zb-agent launchd agent ────────────────

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_SRC="$REPO_DIR/mac-agent/com.zerobridge.zb-agent.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.zerobridge.zb-agent.plist"

if [ -f "$PLIST_SRC" ]; then
    cp "$PLIST_SRC" "$PLIST_DST"
    # Load (or reload if already loaded)
    launchctl bootout "gui/$(id -u)/com.zerobridge.zb-agent" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
    ok "zb-agent launchd agent installed — starts on login, restarts on crash"
    info "Logs: /tmp/zb-agent.log"
    info "Stop:  launchctl bootout gui/$(id -u)/com.zerobridge.zb-agent"
    info "Start: launchctl bootstrap gui/$(id -u) $PLIST_DST"
else
    info "Plist not found at $PLIST_SRC — skipping launchd install"
fi

echo ""
echo "═══════════════════════════════════════"
ok "Mac setup complete"
echo ""
echo "  USB ethernet: $HOST_IP/$NETMASK (static, survives reboot)"
echo "  Pi should be reachable at: 169.254.206.2"
echo "  zb-agent: auto-starts on login (port 8082 on 169.254.206.1)"
echo ""
echo "  Test connectivity:"
echo "    ssh vasugarg@169.254.206.2"
echo "    ssh pi0.hid"
echo "  Check zb-agent:"
echo "    launchctl list | grep zerobridge"
echo "    tail -f /tmp/zb-agent.log"
echo "═══════════════════════════════════════"
