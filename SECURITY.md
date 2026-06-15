# Security Policy

ZeroBridge emulates a **physical USB keyboard and mouse** for a macOS host. By design it can type, click, and run commands on the Mac it is tethered to. That makes input-path integrity and authentication the most security-sensitive parts of the project, and we treat reports against them seriously.

This document covers the **threat model**, what is **in and out of scope**, and how to **report a vulnerability privately**.

---

## Supported Versions

ZeroBridge is pre-1.0 and ships from `main`. Security fixes land on `main` and are not backported.

| Version | Supported |
|---------|-----------|
| `main` (latest) | ✅ |
| Older commits / tags | ❌ |

Always run the latest `main` for security fixes.

---

## Threat Model

ZeroBridge is built for a **single trusted operator** controlling **their own Mac** over a **private USB tether or an isolated/home LAN**.

### Trust boundaries

```
[ Phone / PWA ]  --TLS 1.3 (WSS)-->  [ go-server ]  --unix socket-->  [ pi-agent ]  --USB HID-->  [ Mac ]
       │                                  │                              │
       │  ◄═══════════ P-256 ECDH + AES-256-GCM end-to-end ═══════════►  │
       │            (go-server sees only {"enc":"…"} envelopes)          │
```

* **Phone / PWA** — trusted operator endpoint. Holds the WebAuthn passkey and the PRF-derived encryption key.
* **go-server (Go)** — *semi-trusted relay*. Terminates TLS and proxies WebSocket frames, but **cannot read keystrokes**: the browser and `pi-agent` negotiate an end-to-end key it never sees.
* **pi-agent (Rust)** — *trusted*. It is the hardware keyboard; root on the Pi means full input control of the Mac.
* **Mac host** — the protected asset.

### What ZeroBridge defends against

| Threat | Mitigation |
|--------|------------|
| Network eavesdropping on the local link | TLS 1.3 (WSS) on all browser ↔ server traffic |
| A compromised or curious `go-server` reading keystrokes | P-256 ECDH + AES-256-GCM **end-to-end** encryption; relay sees only `{"enc":"…"}` |
| Unauthorized device connecting | WebAuthn passkey (TouchID/FaceID); enrollment gated by a one-time 6-digit setup code |
| macOS password exposure at rest | Password encrypted client-side with a WebAuthn-PRF-derived AES-256-GCM key; never stored in plaintext, never sent to the server in the clear |
| Remote shell access to the Pi | SSH password auth disabled; public-key only |
| macOS service reachable from WiFi/external | `zb-agent` binds exclusively to the static CDC-ECM USB link |

### What ZeroBridge does NOT defend against (out of scope)

These are **deployment constraints**, not vulnerabilities. Reports about them will be closed as out of scope:

* ⚠️ **Internet exposure.** Do not port-forward `8443` or bind it to a public interface. ZeroBridge assumes a private link.
* ⚠️ **Hostile/shared LAN.** The 6-digit setup code is not yet rate-limited and is brute-forceable on an open network. Use the USB tether in untrusted environments. (Rate limiting is on the roadmap.)
* ⚠️ **A fully compromised Pi.** The Pi *is* the keyboard. Root on the Pi equals full control of the Mac's input.
* ⚠️ **Physical access** to the Mac or the Pi.
* ⚠️ **Self-signed CA trust.** Users install a locally generated root CA; protect that CA key.

---

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report privately through **[GitHub Security Advisories](https://github.com/gargvasu/zerobridge/security/advisories/new)** ("Report a vulnerability"). This keeps the report confidential until a fix is available.

When reporting, please include:

1. A description of the issue and its impact.
2. The component affected (`pi-agent`, `go-server`, PWA, scripts, build/deploy).
3. Steps to reproduce, or a proof of concept.
4. Any suggested remediation.

### What to expect

* **Acknowledgement** within a reasonable time as an individual-maintained project.
* A good-faith effort to validate, fix, and disclose responsibly.
* Credit in the advisory and changelog if you'd like it (let us know).

### Coordinated disclosure

Please give us a reasonable window to ship a fix before any public disclosure. We'll work with you on timing.

---

## Areas of particular interest

If you're auditing ZeroBridge, the highest-value targets are:

* **E2EE handshake** (`pi-agent/src/crypto.rs`, `doECDH` in the PWA) — key derivation, nonce handling, downgrade-to-plaintext paths.
* **Authentication** (`go-server/auth.go`) — WebAuthn verification, JWT issuance/validation, setup-code gating.
* **Credential storage** (`go-server/store.go`) — encrypted blob handling, PRF/split-key modes.
* **The unlock path** (`go-server/unlock.go`) — plaintext password handling before HID injection.
* **Input parsing** in `pi-agent` — anything reachable from the IPC socket or WebSocket.

Thank you for helping keep ZeroBridge and its users safe.
