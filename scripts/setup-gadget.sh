#!/bin/bash
# =============================================================
# zerobridge — USB HID Gadget Setup
# https://github.com/gargvasu/zerobridge.git 
#
# Sets up Raspberry Pi Zero as a composite USB device:
#   /dev/hidg0  — keyboard
#   /dev/hidg1  — mouse
#   /dev/hidg2  — media keys
#   usb0        — USB ethernet (CDC-ECM)
#   /dev/ttyGS0 — USB serial  (CDC-ACM)
#
# Usage:
#   sudo ./scripts/setup-gadget.sh
#
# Environment variables:
#   USB_IP    Pi Zero USB tether IP   (default: 169.254.206.2)
#   HOST_IP   Mac side USB tether IP  (default: 169.254.206.1)
#   USB_NET   Network prefix          (default: 169.254.0.0/16)
# =============================================================
set -e

USB_IP="${USB_IP:-169.254.206.2}"
HOST_IP="${HOST_IP:-169.254.206.1}"
USB_NET="${USB_NET:-169.254.0.0/16}"

# ── Colours ───────────────────────────────────────
GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
info() { echo -e "${BLUE}ℹ  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }

# ── Log to file + stdout ──────────────────────────
exec > >(tee /tmp/mac-hid-setup.log) 2>&1

echo "================================================"
echo "  zerobridge — USB Gadget Setup"
echo "  Pi IP:   $USB_IP"
echo "  Host IP: $HOST_IP"
echo "================================================"
echo ""

# ── Root check ────────────────────────────────────
[ "$EUID" -eq 0 ] || fail "Run as root: sudo ./scripts/setup-gadget.sh"

# ── Load kernel module ────────────────────────────
info "Loading libcomposite..."
modprobe libcomposite
ok "libcomposite loaded"

G=/sys/kernel/config/usb_gadget/machid
cd /sys/kernel/config/usb_gadget/

# ── Wait for UDC ──────────────────────────────────
info "Waiting for USB Device Controller..."
for i in {1..10}; do
    UDC=$(ls /sys/class/udc 2>/dev/null | head -n 1)
    [ -n "$UDC" ] && break
    sleep 1
done
[ -n "$UDC" ] || fail "No UDC found after 10s — is this a Pi Zero?"
ok "UDC: $UDC"

# ── Cleanup old gadget ────────────────────────────
if [ -d "$G" ]; then
    info "Removing existing gadget..."
    echo "" > "$G/UDC" 2>/dev/null || true
    sleep 1
    rm -rf "$G"
fi

# ── Create gadget ─────────────────────────────────
info "Creating gadget..."
mkdir -p "$G" && cd "$G"

# USB descriptor
echo 0x1d6b > idVendor   # Linux Foundation
echo 0x0104 > idProduct  # Multifunction Composite Gadget
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

# Human readable strings
mkdir -p strings/0x409
grep Serial /proc/cpuinfo | awk '{print $3}' > strings/0x409/serialnumber
echo "zerobridge"      > strings/0x409/manufacturer
echo "zerobridge"      > strings/0x409/product

# Configuration
mkdir -p configs/c.1
echo 0x80 > configs/c.1/bmAttributes  # bus powered
echo 250  > configs/c.1/MaxPower      # 250 x 2mA = 500mA

# ── Keyboard HID (hidg0) ──────────────────────────
info "Setting up keyboard (hidg0)..."
mkdir -p functions/hid.usb0
echo 1 > functions/hid.usb0/protocol    # keyboard
echo 1 > functions/hid.usb0/subclass    # boot interface
echo 8 > functions/hid.usb0/report_length
# Standard keyboard HID report descriptor
printf '\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x03\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x03\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0' \
    > functions/hid.usb0/report_desc
ok "Keyboard ready"

# ── Mouse HID (hidg1) ─────────────────────────────
info "Setting up mouse (hidg1)..."
mkdir -p functions/hid.usb1
echo 2 > functions/hid.usb1/protocol    # mouse
echo 1 > functions/hid.usb1/subclass    # boot interface
echo 4 > functions/hid.usb1/report_length
# Standard mouse HID report descriptor
printf '\x05\x01\x09\x02\xa1\x01\x09\x01\xa1\x00\x05\x09\x19\x01\x29\x03\x15\x00\x25\x01\x95\x03\x75\x01\x81\x02\x95\x01\x75\x05\x81\x01\x05\x01\x09\x30\x09\x31\x15\x81\x25\x7f\x75\x08\x95\x02\x81\x06\xc0\xc0' \
    > functions/hid.usb1/report_desc
ok "Mouse ready"

# ── Media Keys HID (hidg2) ────────────────────────
info "Setting up media keys (hidg2)..."
mkdir -p functions/hid.usb2
echo 0 > functions/hid.usb2/protocol    # none
echo 0 > functions/hid.usb2/subclass    # none
echo 2 > functions/hid.usb2/report_length
# Consumer control HID report descriptor
printf '\x05\x0c\x09\x01\xa1\x01\x15\x00\x26\xff\x03\x19\x00\x2a\xff\x03\x75\x10\x95\x01\x81\x00\xc0' \
    > functions/hid.usb2/report_desc
ok "Media keys ready"

# ── USB Ethernet (CDC-ECM) ────────────────────────
info "Setting up USB ethernet..."
mkdir -p functions/ecm.usb0
echo "12:34:56:78:9a:bc" > functions/ecm.usb0/host_addr  # Mac side
echo "12:34:56:78:9a:bd" > functions/ecm.usb0/dev_addr   # Pi side
ok "USB ethernet ready"

# ── USB Serial (CDC-ACM) ──────────────────────────
info "Setting up USB serial..."
mkdir -p functions/acm.usb0
ok "USB serial ready (/dev/ttyGS0)"

# ── Link functions to configuration ──────────────
info "Linking functions..."
ln -sf functions/hid.usb0 configs/c.1/
ln -sf functions/hid.usb1 configs/c.1/
ln -sf functions/hid.usb2 configs/c.1/
ln -sf functions/ecm.usb0 configs/c.1/
ln -sf functions/acm.usb0 configs/c.1/

# ── Attach gadget to UDC ─────────────────────────
info "Attaching gadget to $UDC..."
echo "$UDC" > UDC
ok "Gadget attached"

# ── Network setup ─────────────────────────────────
info "Configuring USB network interface..."
sleep 1

# Clean slate
ip addr flush dev usb0 2>/dev/null || true

# Set static IP
ip addr add "$USB_IP/16" dev usb0
ip link set usb0 up

# Fix routing — use our static IP as source
ip route del "$USB_NET" dev usb0 2>/dev/null || true
ip route add "$USB_NET" dev usb0 src "$USB_IP" 2>/dev/null || true

ok "Network: usb0 at $USB_IP"

# ── /etc/hosts ────────────────────────────────────
if ! grep -q "mac.hid" /etc/hosts; then
    echo "$HOST_IP   mac.hid" >> /etc/hosts
    ok "mac.hid → /etc/hosts"
fi

# ── Summary ───────────────────────────────────────
echo ""
echo "================================================"
ok "mac.hid gadget ready!"
echo ""
echo "  Devices:"
echo "    /dev/hidg0  keyboard"
echo "    /dev/hidg1  mouse"
echo "    /dev/hidg2  media keys"
echo "    /dev/ttyGS0 serial"
echo "    usb0        ethernet ($USB_IP)"
echo ""
echo "  Host reachable at: $HOST_IP (mac.hid)"
echo "  Log: /tmp/mac-hid-setup.log"
echo "================================================"
