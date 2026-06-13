#!/bin/bash
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Colors ────────────────────────────────────────
GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
info() { echo -e "${BLUE}ℹ  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }

echo "═══════════════════════════════════════"
echo "  ZeroBridge — Build"
echo "═══════════════════════════════════════"
echo ""

# ── pi-agent (Rust for ARMv6) ─────────────────────
info "Building pi-agent (Rust → ARMv6)..."
command -v cargo >/dev/null || fail "cargo not found — install Rust"
command -v arm-unknown-linux-gnueabihf-gcc >/dev/null || \
    fail "ARM cross compiler not found — brew install messense/macos-cross-toolchains/arm-unknown-linux-gnueabihf"

cd "$REPO_DIR/pi-agent"
cargo build --release --target arm-unknown-linux-gnueabihf
ok "pi-agent built → pi-agent/target/arm-unknown-linux-gnueabihf/release/pi-agent"

# ── mac-agent (Swift) ─────────────────────────────
info "Building zb-agent (Swift)..."
command -v swiftc >/dev/null || warn "swiftc not found — skipping mac-agent build"
if command -v swiftc >/dev/null; then
    cd "$REPO_DIR/mac-agent"
    swiftc zb-agent.swift -o zb-agent
    ok "zb-agent built → mac-agent/zb-agent"
fi

# ── go-server (Go for ARMv6) ──────────────────────
if [ -f "$REPO_DIR/go-server/go.mod" ]; then
    info "Building go-server (Go → ARMv6)..."
    command -v go >/dev/null || fail "go not found — install Go"
    cd "$REPO_DIR/go-server"
    GOOS=linux GOARCH=arm GOARM=6 go build -o go-server .
    ok "go-server built → go-server/go-server"
else
    warn "go-server/go.mod not found — skipping"
fi

echo ""
echo "═══════════════════════════════════════"
ok "Build complete!"
echo ""
echo "Next: ./scripts/deploy.sh <pi-zero-host>"
echo "═══════════════════════════════════════"