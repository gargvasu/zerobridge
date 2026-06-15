# Contributing to ZeroBridge

Thanks for your interest in improving ZeroBridge! Issues, feature requests, and pull requests are all welcome. This guide explains how to get set up and what we expect from contributions.

> For security vulnerabilities, **do not** open a public issue — see [SECURITY.md](SECURITY.md).

---

## Project layout

ZeroBridge is a three-language project:

| Component | Language | Path | Role |
|-----------|----------|------|------|
| **pi-agent** | Rust | `pi-agent/` | Daemon on the Pi Zero: USB HID, IPC socket, E2EE, hybrid routing |
| **go-server** | Go | `go-server/` | HTTPS/WSS server, WebAuthn, PWA host, encrypted relay |
| **zb-agent** | Swift | `mac-agent/` | macOS helper: clipboard, cursor, screen, window queries |
| **PWA** | HTML/JS | `go-server/static/` | Mobile control UI (no build step, vanilla JS) |
| **scripts** | Bash | `scripts/` | Build, deploy, activate, certs, diagnostics |

The architecture and message flow are documented in the [README](README.md#-architecture--routing-flow).

---

## Development setup

### Prerequisites

* **Rust** (stable) with the ARMv6 target for the Pi Zero:
  ```bash
  rustup target add arm-unknown-linux-gnueabihf
  brew install messense/macos-cross-toolchains/arm-unknown-linux-gnueabihf
  ```
* **Go** (1.26+) — cross-compiles to ARMv6 with the standard toolchain.
* **Swift** (Xcode CLT) — for the macOS agent.
* A **Raspberry Pi Zero W / 2 W** set up per the [Hardware Requirements](README.md#-hardware-requirements) for end-to-end testing.

### Build

The cross-compilation is wired into one script:

```bash
./scripts/build.sh
```

This produces ARMv6 binaries for `pi-agent` and `go-server`. **A clean build is required before submitting a PR.**

You can also build components individually:

```bash
# pi-agent (Rust)
cd pi-agent && cargo build --target arm-unknown-linux-gnueabihf --release

# go-server (Go)
cd go-server && GOOS=linux GOARCH=arm GOARM=6 go build -o go-server .

# zb-agent (Swift, native to your Mac)
cd mac-agent && swiftc zb-agent.swift -o zb-agent
```

### Deploy & iterate

```bash
./scripts/deploy.sh        # copy binaries/assets over the USB tether
./scripts/activate.sh      # swap binaries and restart services on the Pi

# Or, for go-server only, a one-shot build+deploy+restart+logs:
./scripts/zb-ctl.sh deploy-go

# Tail logs while testing
./scripts/zb-ctl.sh log pi-agent
./scripts/zb-ctl.sh log go-server
```

Target a custom Pi with environment variables: `PI_HOST=192.168.1.50 PI_USER=pi ./scripts/deploy.sh`.

---

## Contribution guidelines

### Code style

* **Match the surrounding code.** Each component has an established style — follow the idioms, naming, and comment density already present in the files you touch.
* **Rust:** keep `cargo build` warning-clean; prefer the existing error-as-`String` IPC pattern.
* **Go:** standard `gofmt`; stdlib-first, minimal dependencies.
* **PWA:** vanilla JS, no framework, no build step. Keep it that way.

### Commits & PRs

* Use clear, conventional-style commit messages (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`) — consistent with the existing history.
* Keep PRs focused; one logical change per PR.
* Describe **what** changed and **why**. If behavior changes, say how you verified it (which scripts you ran, what you observed on the Mac).
* Update the [README](README.md) and [CHANGELOG](CHANGELOG.md) when your change is user-visible.

### Security-relevant changes

If your change touches the E2EE handshake, authentication, credential storage, the unlock path, or any IPC/socket parsing:

* Describe the **threat-model impact** in the PR (see [SECURITY.md](SECURITY.md#threat-model)).
* Call out any new trust assumptions or downgrade paths explicitly.
* Avoid introducing new dependencies in crypto-adjacent code without discussion.

### Testing

* Run `./scripts/build.sh` and confirm a clean cross-compile.
* Where practical, exercise the change end-to-end against a live Pi + Mac.
* HID/latency-sensitive changes: validate with `./scripts/latency-diag.sh` (run on the Pi) and the live HID test scripts in `scripts/`.

---

## Reporting bugs & requesting features

* **Bugs:** open an issue with reproduction steps, expected vs. actual behavior, and the affected component. Include relevant logs (`zb-ctl log …`).
* **Features:** check the [Roadmap](README.md#-roadmap--planned-features) first — it may already be planned. Otherwise, describe the use case and proposed behavior.

By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE).
