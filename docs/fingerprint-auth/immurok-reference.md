# Immurok reference and reuse boundaries

Immurok is a useful reference for the *desktop authentication workflow*, but
ZeroBridge must not be treated as a direct firmware port.

## Concepts to adapt

| Immurok concept | ZeroBridge adaptation |
|---|---|
| Sensor-local template matching | Use an R503/R559S-class UART sensor; Pi sees result/ID only |
| Paired device proves a match | Pi signs match approvals for a paired Mac daemon |
| Short pre-authorization window | Use only for an explicit service/action, then consume once |
| PAM module ↔ user daemon Unix socket | `pam_zerobridge.so` ↔ `zb-authd` |
| Screen unlock separate from PAM | Verify match, then type Keychain password only at lock screen |
| Explicit cancel/reject/timeout behavior | Cancel remote challenge when PAM/child process goes away |
| Agent approval bound to command | Sign a request digest, not a general match event |

## Concepts not to port

| Immurok component | Why it does not fit |
|---|---|
| CH592F C firmware | Pi runs Linux/Rust and has different hardware and trust boundary |
| Custom BLE GATT service | ZeroBridge already has a direct USB Ethernet link |
| BLE HID connection anchor | ZeroBridge already presents wired USB HID |
| OTA JumpIAP/IAP bootloaders | Pi software deployment is a different update model |
| Battery/sleep model | Pi is a tethered computer, not a microamp wireless token |
| Dual-host BLE switching | One Pi USB gadget is normally tethered to one Mac |
| On-MCU SSH/TOTP/API keystore | Pi filesystem is not an equivalent secure key store |

## Critical differences

Immurok's dedicated MCU is not a general-purpose host OS and can hold an
application-controlled key alongside a fingerprint sensor. ZeroBridge's Pi
controls USB HID and runs a mutable Linux system. Root on the Pi can inject
keyboard events regardless of fingerprint policy.

Therefore this extension should be described as:

> A fingerprint-gated, locally tethered desktop-control appliance.

It should not be described as a hardware security key or as equivalent to
native Touch ID unless the hardware architecture is changed to introduce an
independent secure signing authority.

## License and provenance

The available Immurok repositories have split licensing:

- macOS/Linux companion applications and PAM modules: Apache License 2.0;
- firmware, OTA tooling, hardware, and docs: Business Source License 1.1
  until its stated change date.

Apache-2.0 code can generally be distributed with an MIT project when license
and NOTICE obligations are preserved. Do not copy BSL-licensed code, hardware
files, documentation, or firmware into ZeroBridge without confirming the
license permits the intended use.

Prefer adapting the protocol ideas and implementing ZeroBridge-native code.
If code is copied from an Apache-2.0 Immurok component, retain its copyright
and license notices and document the source file and revision in the new
file's header.

## Primary source locations in this workspace

- `/Volumes/Corsair/thirdy-pty/immurok/immurok/docs/security.md`
- `/Volumes/Corsair/thirdy-pty/immurok/immurok/docs/protocol.md`
- `/Volumes/Corsair/thirdy-pty/immurok/app-macos/pam/pam_immurok.c`
- `/Volumes/Corsair/thirdy-pty/immurok/app-macos/Sources/PAMSocketServer.swift`
- `/Volumes/Corsair/thirdy-pty/immurok/website/blog-src/content/posts/macos-authentication-modes/index.md`

Read the source and current license before reuse; this document is an
architecture guide, not a license grant.
