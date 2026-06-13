## Quick Install

### Prerequisites
- Raspberry Pi Zero W/2W
- Mac running macOS
- USB cable connecting Pi Zero to Mac

### 1. Mac Setup
```bash
# Install zb-agent
cd mac-agent
swiftc zb-agent.swift -o zb-agent
mkdir -p ~/bin && cp zb-agent ~/bin/
```

### 2. Build (on Mac)
```bash
./scripts/build.sh
```

### 3. Deploy to Pi Zero
```bash
# Default (USB tether)
./scripts/deploy.sh

# Custom host/user
PI_HOST=192.168.0.123 PI_USER=myuser ./scripts/deploy.sh
```

### 4. Install on Pi Zero
```bash
ssh pi@raspberrypizero.local
sudo ZB_USER=pi ./scripts/install.sh
```

### 5. Verify
```bash
echo '{"id":"1","type":"ping"}' | nc -q 1 -U /tmp/zerobridge.sock
# → {"type":"pong","id":"1"}
```