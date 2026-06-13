cat > /Volumes/Corsair/Dev/repos/zerobridge/scripts/multi-hid-setup.sh << 'EOF'
#!/bin/bash
set -e

# ── ZeroBridge USB HID Gadget Setup ───────────────
# Sets up:
#   hidg0 → keyboard
#   hidg1 → mouse
#   hidg2 → media keys
#   ecm.usb0 → USB ethernet
#   acm.usb0 → USB serial
#
# Configurable:
#   USB_IP   — Pi Zero USB tether IP (default: 169.254.206.2)
#   USB_NET  — network prefix       (default: 169.254.0.0/16)

USB_IP="${USB_IP:-169.254.206.2}"
USB_NET="${USB_NET:-169.254.0.0/16}"

# Log to file and stdout
exec > >(tee /tmp/hid-setup.log) 2>&1

echo "═══════════════════════════════════════"
echo "  ZeroBridge HID Gadget Setup"
echo "  USB IP: $USB_IP"
echo "═══════════════════════════════════════"

G=/sys/kernel/config/usb_gadget/pi0
modprobe libcomposite
cd /sys/kernel/config/usb_gadget/

# ── Wait for UDC ──────────────────────────────────
echo "Waiting for UDC..."
for i in {1..10}; do
    UDC=$(ls /sys/class/udc 2>/dev/null | head -n 1)
    [ -n "$UDC" ] && break
    sleep 1
done

if [ -z "$UDC" ]; then
    echo "❌ No UDC found after 10s — aborting"
    exit 1
fi
echo "✅ UDC: $UDC"

# ── Cleanup old state ─────────────────────────────
if [ -d "$G" ]; then
    echo "Cleaning existing gadget..."
    echo "" | tee $G/UDC > /dev/null 2>&1 || true
    sleep 1
    rm -rf $G
fi

# ── Create gadget ─────────────────────────────────
mkdir -p $G
cd $G

# Device info
echo 0x1d6b > idVendor   # Linux Foundation
echo 0x0104 > idProduct  # Multifunction Composite Gadget
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

# Strings
mkdir -p strings/0x409
echo $(grep Serial /proc/cpuinfo | awk '{print $3}') > strings/0x409/serialnumber
echo "Raspberry Pi"  > strings/0x409/manufacturer
echo "ZeroBridge"    > strings/0x409/product

# Config
mkdir -p configs/c.1
echo 0x80 > configs/c.1/bmAttributes
echo 250  > configs/c.1/MaxPower

# ── Keyboard (hidg0) ──────────────────────────────
echo "Setting up keyboard (hidg0)..."
mkdir -p functions/hid.usb0
echo 1 > functions/hid.usb0/protocol
echo 1 > functions/hid.usb0/subclass
echo 8 > functions/hid.usb0/report_length
echo -ne \
"\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\
\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\
\x95\x01\x75\x08\x81\x03\
\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\
\x95\x01\x75\x03\x91\x03\
\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0" \
> functions/hid.usb0/report_desc

# ── Mouse (hidg1) ─────────────────────────────────
echo "Setting up mouse (hidg1)..."
mkdir -p functions/hid.usb1
echo 2 > functions/hid.usb1/protocol
echo 1 > functions/hid.usb1/subclass
echo 4 > functions/hid.usb1/report_length
echo -ne \
"\x05\x01\x09\x02\xa1\x01\x09\x01\xa1\x00\
\x05\x09\x19\x01\x29\x03\x15\x00\x25\x01\
\x95\x03\x75\x01\x81\x02\x95\x01\x75\x05\x81\x01\
\x05\x01\x09\x30\x09\x31\x15\x81\x25\x7f\
\x75\x08\x95\x02\x81\x06\xc0\xc0" \
> functions/hid.usb1/report_desc

# ── Media keys (hidg2) ────────────────────────────
echo "Setting up media keys (hidg2)..."
mkdir -p functions/hid.usb2
echo 0 > functions/hid.usb2/protocol
echo 0 > functions/hid.usb2/subclass
echo 2 > functions/hid.usb2/report_length
echo -ne \
"\x05\x0c\x09\x01\xa1\x01\
\x15\x00\x26\xff\x03\
\x19\x00\x2a\xff\x03\
\x75\x10\x95\x01\
\x81\x00\xc0" \
> functions/hid.usb2/report_desc

# ── Ethernet (CDC-ECM) ────────────────────────────
echo "Setting up USB ethernet (ecm.usb0)..."
mkdir -p functions/ecm.usb0
echo "12:34:56:78:9a:bc" > functions/ecm.usb0/host_addr
echo "12:34:56:78:9a:bd" > functions/ecm.usb0/dev_addr

# ── Serial (CDC-ACM) ──────────────────────────────
echo "Setting up USB serial (acm.usb0)..."
mkdir -p functions/acm.usb0

# ── Link functions to config ──────────────────────
ln -sf functions/hid.usb0 configs/c.1/
ln -sf functions/hid.usb1 configs/c.1/
ln -sf functions/hid.usb2 configs/c.1/
ln -sf functions/ecm.usb0 configs/c.1/
ln -sf functions/acm.usb0 configs/c.1/

# ── Attach to UDC ─────────────────────────────────
echo "$UDC" | tee UDC > /dev/null
echo "✅ HID gadget attached to $UDC"

# ── Network ───────────────────────────────────────
echo "Configuring USB network..."
sleep 1
ip addr flush dev usb0 2>/dev/null || true
ip addr add "$USB_IP/16" dev usb0
ip link set usb0 up
ip route add "$USB_NET" dev usb0 src "$USB_IP" 2>/dev/null || true

# Add hid.macmini to /etc/hosts if not present
grep -q "hid.macmini" /etc/hosts || \
    echo "169.254.206.1   hid.macmini" >> /etc/hosts

echo "✅ usb0 up at $USB_IP"
echo ""
echo "═══════════════════════════════════════"
echo "✅ ZeroBridge HID gadget ready"
echo "   Devices: hidg0 hidg1 hidg2"
echo "   Network: $USB_IP"
echo "   Serial:  /dev/ttyGS0"
echo "   Log:     /tmp/hid-setup.log"
echo "═══════════════════════════════════════"
EOF

chmod +x /Volumes/Corsair/Dev/repos/zerobridge/scripts/multi-hid-setup.sh