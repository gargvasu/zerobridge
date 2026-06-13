#!/bin/bash
set -e

# ── Usage ─────────────────────────────────────────
# ./scripts/build.sh [component...] [--lint] [--check]
#
# Components:  pi  mac  go  (default: all that exist)
# Flags:
#   --lint     run cargo clippy before building pi-agent
#   --check    cargo check only (no cross-compile, fast)
#
# Examples:
#   ./scripts/build.sh               # build everything
#   ./scripts/build.sh pi            # pi-agent only
#   ./scripts/build.sh pi --lint     # clippy then build
#   ./scripts/build.sh pi --check    # fast type-check, no cross-compile
#   ./scripts/build.sh mac           # zb-agent (Swift) only
#   ./scripts/build.sh go            # go-server only

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN='\033[0;32m'; BLUE='\033[0;34m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
info() { echo -e "${BLUE}ℹ  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }

# ── Parse args ────────────────────────────────────
DO_PI=false; DO_MAC=false; DO_GO=false
DO_LINT=false; DO_CHECK=false
EXPLICIT=false

for arg in "$@"; do
    case "$arg" in
        pi)    DO_PI=true;  EXPLICIT=true ;;
        mac)   DO_MAC=true; EXPLICIT=true ;;
        go)    DO_GO=true;  EXPLICIT=true ;;
        --lint)  DO_LINT=true ;;
        --check) DO_CHECK=true ;;
        *) fail "Unknown argument: $arg  (valid: pi mac go --lint --check)" ;;
    esac
done

# Default: build all present components
if [ "$EXPLICIT" = false ]; then
    DO_PI=true
    DO_MAC=true
    [ -f "$REPO_DIR/go-server/go.mod" ] && DO_GO=true
fi

echo "═══════════════════════════════════════"
echo "  ZeroBridge — Build"
[ "$DO_LINT" = true ]  && echo "  + cargo clippy (lint)"
[ "$DO_CHECK" = true ] && echo "  + cargo check only"
echo "═══════════════════════════════════════"
echo ""

# ── pi-agent (Rust → ARMv6) ───────────────────────
if [ "$DO_PI" = true ]; then
    command -v cargo >/dev/null || fail "cargo not found — install Rust"

    cd "$REPO_DIR/pi-agent"

    if [ "$DO_LINT" = true ]; then
        info "Running cargo clippy..."
        # Use host target for clippy (fast, no cross-compiler needed)
        cargo clippy --all-targets -- \
            -D warnings \
            -W clippy::unwrap_used
        ok "Clippy clean"
    fi

    if [ "$DO_CHECK" = true ]; then
        info "Running cargo check (host target, fast)..."
        cargo check --all-targets
        ok "pi-agent check passed"
    else
        command -v arm-unknown-linux-gnueabihf-gcc >/dev/null || \
            fail "ARM cross compiler not found:
  brew install messense/macos-cross-toolchains/arm-unknown-linux-gnueabihf"
        info "Building pi-agent (Rust → ARMv6)..."
        cargo build --release --target arm-unknown-linux-gnueabihf
        ok "pi-agent → pi-agent/target/arm-unknown-linux-gnueabihf/release/pi-agent"
    fi
fi

# ── mac-agent (Swift) ─────────────────────────────
if [ "$DO_MAC" = true ]; then
    if command -v swiftc >/dev/null 2>&1; then
        info "Building zb-agent (Swift)..."
        cd "$REPO_DIR/mac-agent"
        swiftc zb-agent.swift -o zb-agent
        ok "zb-agent → mac-agent/zb-agent"
    else
        warn "swiftc not found — skipping mac-agent"
    fi
fi

# ── go-server (Go → ARMv6) ────────────────────────
if [ "$DO_GO" = true ]; then
    if [ ! -f "$REPO_DIR/go-server/go.mod" ]; then
        warn "go-server/go.mod not found — skipping"
    else
        command -v go >/dev/null || fail "go not found — install Go"
        info "Building go-server (Go → ARMv6)..."
        cd "$REPO_DIR/go-server"
        GOOS=linux GOARCH=arm GOARM=6 go build -o go-server .
        ok "go-server → go-server/go-server"
    fi
fi

echo ""
echo "═══════════════════════════════════════"
ok "Build complete"
echo ""
echo "Next: ./scripts/deploy.sh"
echo "═══════════════════════════════════════"
