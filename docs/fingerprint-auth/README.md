# Fingerprint-gated ZeroBridge

This directory defines a planned ZeroBridge extension: a Raspberry Pi Zero
with a locally matched fingerprint sensor that authorizes selected Mac actions.

It aims to provide the useful desktop workflow of a dedicated fingerprint key:

- touch to unlock an already-running macOS session;
- touch to approve `sudo` and selected PAM-backed authorization prompts;
- touch to approve sensitive ZeroBridge actions and AI-agent commands.

It is **not native Apple Touch ID**. An external Pi cannot enroll fingerprints
in the Secure Enclave, appear in macOS Touch ID settings, unlock FileVault at
boot using biometrics, or satisfy `LAContext`, Apple Pay, and similar
Touch-ID-only interfaces.

## Document map

| Document | Purpose |
|---|---|
| [hardware.md](hardware.md) | Supported sensor class, wiring, power, enclosure, and bring-up |
| [architecture.md](architecture.md) | Components, trust boundaries, and signed-approval protocol |
| [macos-integration.md](macos-integration.md) | Lock-screen, PAM, Keychain, and agent-approval implementation |
| [security.md](security.md) | Threat model, constraints, and mandatory security properties |
| [implementation-plan.md](implementation-plan.md) | Incremental milestones and validation criteria |
| [immurok-reference.md](immurok-reference.md) | Concepts to adapt from Immurok and licensing boundaries |

## Product boundary

ZeroBridge is already a Pi Zero USB gadget. It presents a keyboard, mouse,
media controller, USB Ethernet, and USB serial to one tethered Mac. This
extension adds an on-Pi fingerprint **proof source**; it does not replace the
existing USB HID actuator.

```text
fingerprint sensor ── UART ──> pi-agent ── USB Ethernet ──> Mac daemon/PAM
                                      │
                                      └── USB HID ──> macOS lock screen
```

The core rule is: a sensor match must authorize a specific, short-lived action.
It must never mean “the Pi may type arbitrary input indefinitely.”

## Scope for v1

1. A UART capacitive sensor performs enrollment and matching internally.
2. `pi-agent` exposes sensor status and emits verified, short-lived approvals.
3. A physical match can unlock a locked, already-booted Mac session by typing
   its login password through USB HID.
4. A macOS PAM module can request a fingerprint approval for `sudo`.

SSH signing, TOTP, API-secret storage, password-manager injection, and
multi-host support are intentionally later milestones. They need separate
security design and should not be implied by a fingerprint unlock feature.
