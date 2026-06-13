# 🌉 ZeroBridge

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform: macOS + Raspberry Pi Zero](https://img.shields.io/badge/Platform-macOS%20%2B%20Pi%20Zero-blue.svg)](https://github.com/gargvasu/zerobridge)
[![Language: Rust + Swift](https://img.shields.io/badge/Languages-Rust%20%2B%20Swift%20%2B%20Python-orange.svg)](https://github.com/gargvasu/zerobridge)

**ZeroBridge** turns a Raspberry Pi Zero (W/2W) into a hardware-level automation engine and telemetry bridge for macOS. By emulating a physical multi-device composite USB gadget, it interfaces directly at the hardware layer—providing a reliable, zero-configuration automation experience that remains unaffected by macOS GUI scripting permissions or application sandboxing constraints.

Pipe simple JSON commands into a Unix socket on the Pi, and watch it move the mouse, type hotkeys, control media, or execute terminal workflows on your Mac with native hardware precision.

---

## 🚀 Key Features

* **🔌 Single-Cable Composite Gadget**: Multiplexes **USB Keyboard**, **USB Mouse**, **USB Consumer Keys**, **CDC-ACM Serial**, and **CDC-ECM Ethernet** over a single standard USB connection.
* **🔌 Frictionless Hardware Emulation**: Since the host Mac interfaces with the Pi Zero as a native USB device, automation workflows run reliably without needing complex accessibility GUI permissions, API-level scripting tokens, or app sandbox configuration changes.
* **⚡ Dual-Channel Routing**:
  * **Ultra-Low Latency Serial**: Uses USB serial (`/dev/ttyGS0` ↔ `/dev/tty.usbmodem*`) for high-frequency telemetry (cursor positions, active window state, screen configuration).
  * **Robust SSH Connection Pool**: Executes complex workflows, handles large clipboard buffers, and launches scripts on the host Mac using standard SSH over the USB-ethernet bridge (with automatic WiFi failover).
* **🖥️ Screen-Aware Mouse Movement**: Automatically fetches multi-monitor layouts and translates coordinate metrics so mouse sweeps, clicks, and drag-and-drops map correctly across screens.
* **🤖 Simple Unix Socket IPC**: Send a JSON string to `/tmp/zerobridge.sock` on the Pi to trigger macro sequences.

---

## 📐 How It Works

```
                        ┌─────────────────────────┐
                        │       macOS Host        │
                        │  (AppKit/Quartz APIs)   │
                        └─────────▲─────────▲─────┘
                                  │         │
                 (USB Serial Line)│         │(SSH over CDC-ECM)
                        ┌─────────▼─┐     ┌─▼─────────┐
                        │mac_agent  │     │zb-agent   │
                        │(Python)   │     │(Swift)    │
                        └─────────▲─┘     └─▲─────────┘
                                  │         │
 ═════════════════════════════════╪═════════╪═══════════════════ USB Connection
                                  │         │
                        ┌─────────▼─┐     ┌─▼─────────┐
                        │/dev/ttyGS0│     │usb0 (IP)  │
                        │(ACM Serial)     │(Ethernet) │
                        └─────────▲─┘     └─▲─────────┘
                                  │         │
                             ┌────┴─────────┴────┐
                             │    MacBridge      │
                             └────────▲──────────┘
                                      │
  [ IPC Socket ] ────────►  ┌─────────┴─────────┐
  (/tmp/zerobridge.sock)     │  pi-agent (Rust)  │
                             └────────┬─────────┘
                                      │
                                      ├──────────────┬──────────────┐
                                      ▼              ▼              ▼
                                 Keyboard          Mouse          Media
                               (/dev/hidg0)   (/dev/hidg1)   (/dev/hidg2)
```

---

## 🔒 Security & Hardening

ZeroBridge is designed with safety and device boundaries in mind:

* **🔌 USB-Only macOS SSH Binding**: Hardens the macOS host by configuring the SSH daemon (`sshd_config`) to listen exclusively on the CDC-ECM USB link (`169.254.206.1`). This blocks any incoming remote connections to the Mac over the local WiFi or external interfaces.
* **🔑 Pubkey-Locked Pi Zero SSH**: The Pi Zero's SSH daemon is locked down by disabling password authentication (`PasswordAuthentication no`). The system is only accessible to computers presenting an authorized cryptographic SSH key.
* **🛡️ Local Socket Boundary**: The IPC control channel `/tmp/zerobridge.sock` is locally scoped to the Pi Zero's filesystem with Unix permissions. It does not open any external network ports, meaning remote clients cannot send automated keys or mouse actions.
* **⚡ Zero-Trust Interface Routing**: The SSH pool ignores default WiFi/ethernet routing for primary actions, forcing traffic directly down the point-to-point physical USB tether. This isolates host administration traffic from local network snooping.

---

## 🛠️ Quick Start

### 1. Mac Setup
Compile the host-side helper binary. This Swift program handles advanced windows queries, focus actions, and console workflows.
```bash
# Build the Mac agent helper
cd mac-agent
swiftc zb-agent.swift -o zb-agent
mkdir -p ~/bin && cp zb-agent ~/bin/
```

### 2. Build the Pi Agent (on Mac)
Cross-compile the Rust agent target for the Pi Zero's ARMv6 architecture:
```bash
./scripts/build.sh
```

### 3. Deploy to the Pi Zero
Copy the built binaries, configuration files, and systemd units over USB tethering:
```bash
# Deploys using the default tether IP (169.254.206.2)
./scripts/deploy.sh

# Or target a custom host/user:
PI_HOST=192.168.1.50 PI_USER=pi ./scripts/deploy.sh
```

### 4. Install & Launch on the Pi Zero
SSH into the Pi to run the installation script. This script configures Linux `configfs` to initialize the composite USB gadgets on boot:
```bash
ssh pi@raspberrypizero.local
sudo ZB_USER=pi ./scripts/install.sh
```

---

## ⌨️ Controlling your Mac (IPC Examples)

Once installed, control your Mac by piping simple JSON payloads to the Pi's local Unix socket:

### 🔗 Ping Test
Verify the connection to the daemon:
```bash
echo '{"id":"1","type":"ping"}' | nc -q 1 -U /tmp/zerobridge.sock
# Output: {"type":"pong","id":"1"}
```

### 🐭 Move the Mouse & Click
Move the cursor relative to its current position and trigger clicks:
```bash
# Move cursor 100 pixels right and 50 pixels down
echo '{"id":"2","type":"mouse_move","dx":100,"dy":50}' | nc -q 1 -U /tmp/zerobridge.sock

# Trigger a right-click
echo '{"id":"3","type":"mouse_click","button":"right"}' | nc -q 1 -U /tmp/zerobridge.sock
```

### 📝 Smart Typing
Execute complex keystrokes or type text:
```bash
# Launch Spotlight, search for Terminal, and open it
echo '{"id":"4","type":"type_smart","text":"[CMD+SPACE]Terminal[ENTER]"}' | nc -q 1 -U /tmp/zerobridge.sock
```

### 🔊 Adjust Media & Volume
Control the system volume, screen brightness, or media playback:
```bash
# Raise the volume
echo '{"id":"5","type":"media_key","key":"volume_up"}' | nc -q 1 -U /tmp/zerobridge.sock

# Play or Pause media
echo '{"id":"6","type":"media_key","key":"play_pause"}' | nc -q 1 -U /tmp/zerobridge.sock
```

### 📂 Execute Host Commands
Run shell commands directly on your Mac and receive the terminal output on the Pi:
```bash
echo '{"id":"7","type":"run_command","cmd":"ls -la ~/Documents"}' | nc -q 1 -U /tmp/zerobridge.sock
```

---

## 📜 License

ZeroBridge is open-source software licensed under the [MIT License](LICENSE).