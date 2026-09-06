# Architecture and approval protocol

## Design goal

The fingerprint sensor proves local operator presence. The Mac decides which
operation that proof may authorize. A successful match is not a globally valid
“unlock” event.

```text
                 paired, authenticated USB-Ethernet link
+------------------+                              +----------------------+
| Pi Zero          |                              | macOS                |
|                  |                              |                      |
| UART FP sensor   |-- match --> fingerprint ---->| zb-authd             |
| (template flash) |              service         | - verifies approval  |
|                  |                              | - PAM socket server  |
| pi-agent         |<-- action-bound challenge ---| - Keychain access    |
| - policy         |                              |                      |
| - nonce signing  |------ approved response ---->| pam_zerobridge.so    |
| - USB HID        |                              |                      |
+--------+---------+                              +----------------------+
         |
         +---- USB HID keyboard ----> macOS lock screen
```

## Components to add

### Pi: `pi-agent`

Add a fingerprint subsystem, conceptually:

- `fingerprint/transport.rs`: serial configuration, framing, timeout, retries;
- `fingerprint/sensor.rs`: sensor commands for identify, enroll, delete, sleep;
- `fingerprint/policy.rs`: maps requests to a single pending action;
- `fingerprint/approval.rs`: creates action-bound signed approval responses.

Extend `IpcRequest` only with administrative/status commands. Sensitive
operations must be requested by the paired Mac daemon, not an arbitrary local
socket client. The existing `/tmp/zerobridge.sock` is currently mode `0666`;
that is inappropriate as the authorization boundary for fingerprint operations.

### macOS: `zb-authd`

Create a separate, per-user LaunchAgent rather than putting privileged
authentication directly into `zb-agent`:

- owns a private Unix socket at `~/.zerobridge/auth.sock`;
- receives PAM requests and validates the connecting peer;
- communicates with the paired Pi over the USB Ethernet interface;
- tracks pending, approved, rejected, expired, and cancelled requests;
- accesses Keychain only for the screen-unlock path;
- exposes no network listener except the existing, explicitly paired Pi link.

### macOS: `pam_zerobridge.so`

The module should be small C code with no sensor or network knowledge:

1. receive user and PAM service;
2. connect to the user's `zb-authd` Unix socket;
3. wait for `OK`, `DENY`, `TIMEOUT`, or `CANCEL`;
4. return PAM success only for `OK`.

Install it ahead of password fallback in `sudo_local` first. Expand to other
PAM services only after each is tested independently.

## Pairing

Pairing must bind one Pi identity to one Mac user/account.

Recommended v1:

1. Pi creates an Ed25519 keypair on first setup.
2. Mac creates its own Ed25519 keypair in Keychain or a protected app store.
3. A locally initiated setup flow displays/verifies a one-time pairing code.
4. The two sides exchange public keys over the direct USB network.
5. Each persists the peer public key and a pairing identifier.

Using a static signing identity is simpler and more suitable than copying
Immurok's BLE ECDH protocol exactly. Its purpose is different: here, the
USB Ethernet link needs device identity and replay-safe authorization messages.
Use an authenticated key agreement later if session confidentiality is required.

## Request/response protocol

Every PAM or high-risk action must use a fresh random nonce.

```json
{
  "type": "fingerprint_request",
  "request_id": "uuid",
  "nonce": "base64-32-random-bytes",
  "user": "vasugarg",
  "service": "sudo",
  "action": "pam_auth",
  "issued_at": "RFC3339",
  "expires_at": "RFC3339"
}
```

The Pi shows a waiting state, asks the sensor to identify a fingerprint, and
returns either a rejection or an approval:

```json
{
  "type": "fingerprint_approval",
  "request_id": "uuid",
  "nonce": "same nonce",
  "finger_id": 2,
  "action": "pam_auth",
  "service": "sudo",
  "expires_at": "RFC3339",
  "signature": "Ed25519 signature over canonical payload"
}
```

The Mac must reject responses when any of these differ: signature, pairing ID,
request ID, nonce, action, user, service, expiry, or expected peer address.
Each request ID and nonce is single-use.

## Approval state machine

Only one fingerprint-sensitive action may be pending per Pi:

```text
idle → requested → matching → approved | denied | timeout | cancelled
```

Rules:

- Default expiry: 10 seconds; PAM may wait longer only to allow retries.
- A fingerprint approval is consumed exactly once.
- A disconnected PAM client cancels the request.
- A fingerprint match with no pending request must not approve `sudo`.
- Screen unlock may have a separate, explicit short pre-auth window.
- Approval logs contain action/result/timestamp—not passwords, secrets,
  biometric values, or raw sensor frames.

## Screen unlock flow

Screen unlock cannot be completed by a macOS third-party PAM module. The
approved flow is:

1. Pi detects a match while the feature is enabled.
2. `zb-authd` checks that the Mac session is locked.
3. `zb-authd` loads the login password from the macOS Keychain.
4. Pi types it through USB HID and presses Return.
5. Both sides erase the transient request/password buffers.

This is password injection, deliberately limited to a verified locked-screen
state. It must never run while the desktop is active.
