# 🌉 ZeroBridge

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform: macOS + Raspberry Pi Zero](https://img.shields.io/badge/Platform-macOS%20%2B%20Pi%20Zero-blue.svg)](https://github.com/gargvasu/zerobridge)
[![Language: Rust + Swift + Go](https://img.shields.io/badge/Languages-Rust%20%2B%20Swift%20%2B%20Go-orange.svg)](https://github.com/gargvasu/zerobridge)

**ZeroBridge** turns a Raspberry Pi Zero (W/2W) into a hardware-level automation engine and telemetry bridge for macOS. By emulating a physical multi-device composite USB gadget, it interfaces directly at the hardware layer—providing a reliable, zero-configuration automation experience that remains unaffected by macOS GUI scripting permissions, accessibility popups, or application sandboxing constraints.

Pipe JSON commands into a Unix socket on the Pi, or connect securely to the Go Web Server to type keys, move the mouse, control media, or execute terminal commands from any mobile browser (PWA) with native hardware precision.

---

## ✨ Key Features

* **🔌 Single-Cable Composite USB Gadget**: Multiplexes **USB Keyboard**, **USB Mouse**, **USB Consumer (Media) Keys**, **CDC-ACM Serial**, and **CDC-ECM Ethernet** over a single standard USB OTG cable.
* **🛡️ Sandboxing & Permission Bypass**: Since the host Mac interfaces with the Pi Zero as a native hardware USB keyboard and mouse, automation workflows run reliably without needing complex accessibility GUI permissions, API-level scripting tokens, or app sandbox configuration changes.
* **📱 Progressive Web App (PWA) Control**: Serves a mobile-friendly Progressive Web App (PWA) client interface directly from the Pi Zero, featuring a virtual touchpad, keyboard entry, system media keys, and live telemetry on mobile devices.
* **🔐 Passwordless Passkey Security (WebAuthn)**: Secured by local WebAuthn credentials (TouchID / FaceID) to lock out unauthorized devices, with administrative enrollment gated by a temporary 6-digit setup code.
* **🔒 Remote Lock, Wake & Unlock**: Wirelessly lock, wake, and unlock the host Mac. Leverages hardware-emulated keystrokes to wake (double `TAB`) and lock (`ctrl+cmd+q` shortcut) macOS, and queries live system lock/display status (`get_mac_state`) before securely typing the password via HID.
* **⚡ Intelligent Hybrid Routing**:
  * **Sub-Millisecond WebSocket Channel**: Uses a low-overhead WebSocket protocol over USB-ethernet for lightning-fast queries (active window states, window coordinates, screen geometry).
  * **High-Frequency Serial line**: Interfaced directly at the driver level via ACM serial (`/dev/ttyGS0` ↔ `/dev/tty.usbmodem*`) for high-frequency telemetry.
  * **Robust SSH Connection Pool**: Executes complex terminal commands, exchanges clipboard buffers, and runs automation scripts on the Mac with an automated WiFi failover mechanism if USB ethernet is interrupted.
* **🖥️ Screen-Aware Mouse Movement**: Automatically fetches macOS multi-monitor geometry and translates coordinate metrics so mouse sweeps, drag-and-drops, and clicks map correctly across different screens.
* **📁 Local Data Persistence & TLS**: Built-in TLS cert generator (`scripts/gen-certs.sh`) for `zerobridge.local`, featuring a downloadable CA certificate (`/ca.crt`) for client device installation, and persistent storage (`/etc/zerobridge/store.json`) for registered passkeys.

---

## 📐 Architecture & Routing flow

```
                               ┌─────────────────────────┐
                               │       macOS Host        │
                               │  (AppKit/Quartz APIs)   │
                               └─────────▲─────────▲─────┘
                                         │         │
                          (USB Serial)   │         │ (WS / SSH over CDC-ECM)
                               ┌─────────▼─┐     ┌─▼─────────┐
                               │zb-agent   │     │zb-agent   │
                               │(Swift CLI)│     │(WS Server)│
                               └─────────▲─┘     └─▲─────────┘
                                         │         │
         ════════════════════════════════╪═════════╪═══════════════════ USB OTG Connection
                                         │         │
                               ┌─────────▼─┐     ┌─▼─────────┐
                               │/dev/ttyGS0│     │usb0 (IP)  │
                               │(ACM Serial)     │(Ethernet) │
                               └─────────▲─┘     └─▲─────────┘
                                         │         │
                                     ┌───┴─────────┴───┐
                                     │    MacBridge    │
                                     │ (Hybrid Router) │
                                     └────────▲────────┘
                                              │
    [ Local Socket IPC ] ─┐                   │
    (/tmp/zerobridge.sock)├──► ┌──────────────┴───┐
                          │    │  pi-agent (Rust) │
                          │    └────────┬─────────┘
                          │             │
                          │             ├──────────────────┬──────────────────┐
                          │             ▼                  ▼                  ▼
                          │         Keyboard             Mouse              Media
                          │       (/dev/hidg0)       (/dev/hidg1)       (/dev/hidg2)
                          │
     ┌──────────────┐     │ (WS Proxy)
     │  go-server   │◄────┘
     │  (Go HTTPS)  │
     └──────▲───────┘
            │
            │ (PWA Client over HTTPS / TLS)
            ▼
     ┌──────────────┐
     │ Mobile / PWA │
     │ (Touch/Keys) │
     └──────────────┘
```

---

## 🔒 Security & Hardening

ZeroBridge is designed with safety and device boundaries in mind:

* **🔌 USB-Only macOS Service Binding**: Hardens the macOS host by configuring the Swift daemon (`zb-agent serve`) to bind exclusively to the static CDC-ECM link (`169.254.206.1`). This prevents any incoming automation requests or telemetry queries from the local WiFi or external interfaces.
* **🔐 WebAuthn & Localized Authentication**: Authentication is performed cryptographically using Passkeys (TouchID / FaceID). Credentials and cryptographic secrets are stored in a persistent local store (`/etc/zerobridge/store.json`) on the Pi, and registration is gated by a temporary 6-digit administrative setup code generated only on the local Pi or macOS host.
* **🛡️ TLS-Encrypted Transport**: The Go Web Server runs over TLS 1.3 to secure web views and WebSocket sessions. Certificates are signed by a locally generated CA, isolating network traffic from local snooping.
* **🔑 Pubkey-Locked Pi Zero SSH**: The Pi Zero's SSH daemon is locked down by disabling password authentication (`PasswordAuthentication no`). The system is only accessible to computers presenting authorized cryptographic SSH keys.
* **🛡️ Local Socket Boundary**: The IPC control channel `/tmp/zerobridge.sock` is locally scoped to the Pi Zero's filesystem with Unix permissions (`0666`). It does not open external network ports, meaning remote clients cannot send automated keys or mouse actions.

---

## 🛠️ Automated Setup

### 1. Mac Host Setup
Compile the host-side helper binary and automate network interface binding.
```bash
# Clone the repository and build the Mac agent helper
cd mac-agent
swiftc zb-agent.swift -o zb-agent
mkdir -p ~/bin && cp zb-agent ~/bin/

# Automate USB Network setup, hosts configuration, firewall privileges, and Launchd loading
cd ..
./scripts/setup-mac.sh
```

To manage the macOS daemon, use the controller utility:
```bash
# Check the status of the launchd daemon
./scripts/zb-agent-ctl.sh status

# Start/Stop/Restart the agent
./scripts/zb-agent-ctl.sh start
./scripts/zb-agent-ctl.sh stop
./scripts/zb-agent-ctl.sh restart
```

To manage the Pi Zero services directly from the Mac host, use the `zb-ctl` script:
```bash
# Check status of Pi services (go-server & pi-agent)
./scripts/zb-ctl.sh status

# Tail logs on the Pi Zero
./scripts/zb-ctl.sh log go-server
./scripts/zb-ctl.sh log pi-agent
```

### 2. Build the Pi Agent & Go Server (on Mac)
The binaries are cross-compiled on the Mac for the Pi Zero's ARMv6 architecture. 

**Pre-requisites:**
Install the cross-compilation toolchain on macOS:
```bash
brew install messense/macos-cross-toolchains/arm-unknown-linux-gnueabihf
```

Compile the agent and server:
```bash
./scripts/build.sh
```

### 3. Deploy and Activate
Copy the built binaries, configuration files, and systemd units over the USB tethering link:
```bash
# Copy binaries & assets to the default tether IP (169.254.206.2)
./scripts/deploy.sh

# Swap the new binaries in and restart services on the Pi Zero
./scripts/activate.sh
```

*Note: To target a custom SSH host or user, pass them as environment variables:*
```bash
PI_HOST=192.168.1.50 PI_USER=pi ./scripts/deploy.sh
```

Initialize/regenerate TLS certificates on the Pi Zero:
```bash
# Generate CA and server keys on the Pi, then restart go-server
./scripts/zb-ctl.sh regen-certs
```

### 4. PWA Registration & Enrollment
1. Open your mobile browser and navigate to `https://169.254.206.2:8443` (or the IP configured on your Pi Zero).
2. Download and install the custom root CA certificate from `https://169.254.206.2:8443/ca.crt` (on iOS, go to Settings → Profile Downloaded → Install, then Settings → About → Certificate Trust Settings → enable Full Trust for the CA).
3. Open the web app. You will be prompted to enter an enrollment code.
4. On your Mac, run:
   ```bash
   ./scripts/zb-ctl.sh setup-code
   ```
5. Enter the generated 6-digit code in the mobile client and complete the WebAuthn registration process using TouchID/FaceID. Your device is now authorized!

### 5. Secure Lock, Wake, and Unlock Flow
Once authorized via WebAuthn, the PWA client coordinates screen status querying and hardware key simulation to securely wake, lock, and unlock your macOS host:
* **Wake Display**: Sends virtual double `TAB` key events via the USB HID keyboard emulator on the Pi to wake the macOS host from display sleep.
* **Lock Screen**: Commands the hardware emulation layer to send the standard macOS lock-screen shortcut (`ctrl+cmd+q`) directly.
* **Smart Unlock**: 
  1. The client first queries active display power and lock status using the `get_mac_state` command.
  2. If the Mac is already awake and unlocked, the client skips password entry to avoid typing in open fields.
  3. If the Mac is asleep or locked, it decrypts your macOS password from local client-side storage (authorized by local Passkey validation) and POSTs to `/api/unlock`. The Go Server then sends the password via the emulated USB keyboard device followed by `ENTER`.

---

## 🎛️ Complete IPC API Reference

ZeroBridge accepts JSON payloads over `/tmp/zerobridge.sock` (and proxies WebSocket traffic through the Go Server `/ws` endpoint). Every request must include an `"id"` correlation token (string).

### 1. Host Telemetry & Queries

#### 🖱️ Get Cursor Position (`get_cursor`)
Retrieves the current coordinates of the mouse cursor on the Mac host.
* **Request:** `{"id":"1", "type":"get_cursor"}`
* **Response:** `{"type":"cursor_pos", "id":"1", "x":540.2, "y":320.0}`

#### 🖥️ Get Screens Layout (`get_screens`)
Retrieves connected monitors, screen IDs, bounds, dimensions, and arrangement metrics.
* **Request:** `{"id":"2", "type":"get_screens"}`
* **Response:**
  ```json
  {
    "type": "screens",
    "id": "2",
    "layout": [
      {"id": 0, "x": 0, "y": 0, "w": 1920, "h": 1200},
      {"id": 1, "x": 1920, "y": 120, "w": 2560, "h": 1440}
    ]
  }
  ```

#### 📋 Get Clipboard Text (`get_clipboard`)
Fetches the current text stored in the macOS general pasteboard.
* **Request:** `{"id":"3", "type":"get_clipboard"}`
* **Response:** `{"type":"clipboard", "id":"3", "text":"Copied string contents"}`

#### 📱 Get Active Application (`get_active_app`)
Retrieves the name and bundle identifier of the frontmost focused application.
* **Request:** `{"id":"4", "type":"get_active_app"}`
* **Response:** `{"type":"active_app", "id":"4", "name":"Safari", "window":""}`

#### 🪟 Get All Open Windows (`get_windows`)
Lists all visible application windows, including coordinate geometry, dimensions, app name, and titles.
* **Request:** `{"id":"5", "type":"get_windows"}`
* **Response:**
  ```json
  {
    "type": "windows",
    "id": "5",
    "list": [
      {"id": 482, "pid": 9821, "app": "Terminal", "title": "zsh", "x": 200, "y": 150, "w": 800, "h": 500}
    ]
  }
  ```

#### 🔍 Get Window info for App (`get_window_for_app`)
Retrieves the geometry coordinates of the primary window for a specific application.
* **Request:** `{"id":"6", "type":"get_window_for_app", "app":"Terminal"}`
* **Response:**
  ```json
  {
    "type": "window",
    "id": "6",
    "info": {"id": 482, "pid": 9821, "app": "Terminal", "title": "zsh", "x": 200, "y": 150, "w": 800, "h": 500}
  }
  ```

#### 🎯 Focus Application (`focus_app`)
Brings the targeted application to the front and focuses it.
* **Request:** `{"id":"7", "type":"focus_app", "app":"Terminal"}`
* **Response:** `{"type":"focus_result", "id":"7", "app":"Terminal", "success":true}`

#### 🔒 Get Mac State (`get_mac_state`)
Queries the display sleep and screen lock states of the host Mac.
* **Request:** `{"id":"20", "type":"get_mac_state"}`
* **Response:**
  ```json
  {
    "type": "mac_state",
    "id": "20",
    "state": "active",
    "locked": false,
    "display_sleep": false
  }
  ```
  *(Supported `"state"` values: `"active"`, `"locked"`, `"display_sleep"`)*

---

### 2. Hardware Emulation & Automation

#### 🐭 Mouse Relative Move (`mouse_move`)
Moves the cursor relative to its current coordinates.
* **Request:** `{"id":"8", "type":"mouse_move", "dx":100, "dy":-50}`
* **Response:** `{"type":"ok", "id":"8"}`

#### 🖱️ Mouse Click (`mouse_click`)
Triggers a click event at the current cursor coordinates.
* **Request:** `{"id":"9", "type":"mouse_click", "button":"left"}` *(Supported: `left`, `right`, `middle`)*
* **Response:** `{"type":"ok", "id":"9"}`

#### 📜 Mouse Scroll (`mouse_scroll`)
Sends scroll wheel offsets.
* **Request:** `{"id":"10", "type":"mouse_scroll", "delta":-5}`
* **Response:** `{"type":"ok", "id":"10"}`

#### ⌨️ Send Keyboard Combo (`key`)
Simulates key presses with optional hardware modifier flags.
* **Request:**
  ```json
  {
    "id": "11",
    "type": "key",
    "code": "c",
    "modifiers": ["command"]
  }
  ```
* **Response:** `{"type":"ok", "id":"11"}`

#### 📝 Type Literal Text (`type_text`)
Simulates sequential keystrokes for standard alphanumeric text.
* **Request:** `{"id":"12", "type":"type_text", "text":"Hello, ZeroBridge!"}`
* **Response:** `{"type":"ok", "id":"12"}`

#### ⚡ Type Smart macro (`type_smart`)
Parses and types composite macro chains including special bracket keys.
* **Request:** `{"id":"13", "type":"type_smart", "text":"[CMD+SPACE]Safari[ENTER]"}`
* **Response:** `{"type":"ok", "id":"13"}`

#### 🔊 Media Key (`media_key`)
Simulates hardware consumer control keys like system volume, brightness, or playback.
* **Request:** `{"id":"14", "type":"media_key", "key":"volume_up"}`
* **Response:** `{"type":"ok", "id":"14"}`
* *Supported keys: `play_pause`, `next`, `prev`, `volume_up`, `volume_down`, `mute`, `brightness_up`, `brightness_down`*

#### 🛑 Release Inputs (`release`)
Releases all keyboard modifiers and mouse clicks currently held down.
* **Request:** `{"id":"15", "type":"release"}`
* **Response:** `{"type":"ok", "id":"15"}`

---

### 3. Remote Shell & Daemon Management

#### 📂 Execute Host Command (`run_command`)
Runs a shell script or terminal command in the background on the macOS host over the secure SSH tunnel connection.
* **Request:** `{"id":"16", "type":"run_command", "cmd":"ls -la ~/Downloads"}`
* **Response:** `{"type":"command_result", "id":"16", "output":"drwxr-xr-x...", "error":""}`

#### 🔋 Status Probe (`status`)
Queries health states of the internal WebSocket connections and SSH failover channels.
* **Request:** `{"id":"17", "type":"status"}`
* **Response:**
  ```json
  {
    "type": "status_info",
    "id": "17",
    "ws_healthy": true,
    "ssh_usb_healthy": true,
    "ssh_wifi_healthy": false
  }
  ```

#### 🔄 Reset HID State (`reset`)
Fully flushes keyboard and mouse queues and resets key mappings.
* **Request:** `{"id":"18", "type":"reset"}`
* **Response:** `{"type":"ok", "id":"18"}`

#### 🏓 Ping (`ping`)
Tests connection to the Pi local daemon.
* **Request:** `{"id":"19", "type":"ping"}`
* **Response:** `{"type":"pong", "id":"19"}`

---

## ⚙️ Configuration File Guide

To customize ZeroBridge parameters, copy `config/config.toml.example` to `~/.config/zerobridge/config.toml` on the Pi Zero and configure the properties:

```toml
[ssh]
user           = "mac-user"                      # SSH user configured on the Mac host
key            = "/home/pi/.ssh/id_ed25519"      # Authorized private key path on the Pi
port           = 22                              # SSH port on the Mac
timeout_ms     = 5000                            # Timeout threshold for commands
zb_agent_path  = "~/bin/zb-agent"                # Path to zb-agent on the Mac (change to ~/bin/zb-agent-dev to test a dev build)

[hosts]
usb  = "mac.hid"                                 # Primary static IP / Domain over USB connection
wifi = "192.168.0.100"                           # Fallback hostname or IP over local network WiFi

[serial]
device            = "/dev/ttyGS0"                # Linux serial gadget path
timeout_ms        = 3000
cursor_timeout_ms = 1000

[hid]
keyboard = "/dev/hidg0"                          # Dev node mapping for keyboard
mouse    = "/dev/hidg1"                          # Dev node mapping for mouse
media    = "/dev/hidg2"                          # Dev node mapping for media control

[bridge]
# "hybrid"    - WebSocket primary, SSH fallback (Recommended)
# "websocket" - Pure high performance WebSocket connection
# "ssh"       - Force secure SSH tunnels only
# "serial"    - Force raw serial lines only
mode = "hybrid"

[websocket]
url        = "ws://mac.hid:8082"                 # WebSocket URI targeting macOS daemon
timeout_ms = 2000
```

---

## 📊 Latency & Performance

Measured on Pi Zero W over USB CDC-ECM tether to Mac Mini:

| Channel | First request | Steady state | Notes |
|---|---|---|---|
| **WebSocket** | ~50 ms | ~45–55 ms | Primary path; persistent connection |
| **SSH USB fallback** | ~277 ms | ~75–105 ms | Persistent shell channel; one-time setup cost |
| **SSH WiFi fallback** | ~310 ms | ~110–140 ms | Used only if USB tether is down |
| **End-to-end keystroke** | — | ~80 ms | IPC → HID report written to Mac |

> **nc -q1 artifact:** tools that measure via `echo … | nc -q1 -U /tmp/zerobridge.sock` will report ~1050 ms — the extra 1000 ms is `nc` waiting after stdin closes, not real latency. Use `nc -q0` for accurate numbers. The `latency-diag.sh` script handles this correctly.

Key optimisations already applied:
- **Persistent SSH shell channel** — eliminates the ~280 ms per-channel-open overhead; steady state drops to 75–105 ms
- **TAP_DELAY_MS = 10 ms** — reduced from 30 ms; cuts per-keystroke HID time by 40 ms
- **WebSocket primary** — sub-100 ms for all query commands (cursor, clipboard, active app) in hybrid mode

To measure your own baseline:
```bash
# Run on the Pi against a live daemon
./scripts/latency-diag.sh
```

---

## 📜 License

ZeroBridge is open-source software licensed under the [MIT License](LICENSE).