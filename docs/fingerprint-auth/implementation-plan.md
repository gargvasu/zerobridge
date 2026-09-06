# Implementation plan

Implement in independently testable milestones. Do not enable PAM or automatic
password typing until the prior milestone is complete.

## Milestone 0 — hardware spike

Goal: prove the exact sensor works reliably with the intended Pi, cable, and
Mac-powered gadget setup.

- Select a documented 3.3 V UART capacitive sensor.
- Wire UART, ground, switched sensor power, and touch/interrupt.
- Configure the Pi UART for the sensor's documented framing (commonly 57600
  8N2) and disable serial console/Bluetooth conflicts.
- Build a throwaway diagnostic that reports device info, capture, identify,
  sleep, wake, and power-cycle results.
- Test 100+ repeated matches, several unenrolled fingers, held fingers,
  cable reconnects, and Pi reboot.

Exit criteria: matching is reliable; sensor recovery needs no manual cable
reseating; Pi does not brown out on capture.

## Milestone 1 — sensor service in pi-agent

Goal: make sensor access safe, serialized, and observable.

- Add UART transport with framing, deadlines, typed errors, and redacted logs.
- Add sensor commands: status, enroll, identify, delete, sleep, wake.
- Add GPIO interrupt/power control.
- Allow only one active sensor operation.
- Add CLI or local-only administrative commands for enrollment/list/delete.
- Persist only allowed template IDs and human labels; never template data.

Exit criteria: daemon restart and sensor failure recover automatically; no
normal log contains biometric material or raw frames.

## Milestone 2 — local fingerprint action gate

Goal: gate a harmless existing ZeroBridge action.

- Add a pending-action state machine with 10-second expiry.
- Add one action such as a configured media-key command or local status change.
- Require an exact match from an allowed template ID.
- Reject stale, duplicate, or unmatched results.
- Display a visible accepted/rejected state.

Exit criteria: each match authorizes one action only; a prior match cannot be
replayed or reused.

## Milestone 3 — paired Pi/Mac approval channel

Goal: let the Mac trust a specific Pi approval.

- Create `zb-authd` as a per-user LaunchAgent.
- Implement explicit local pairing with persistent public keys.
- Define canonical request/approval serialization.
- Have Pi sign action-bound approval responses.
- Have Mac validate peer key, request ID, nonce, user, service, digest, and
  expiry before accepting.
- Keep the existing PWA relay out of this protocol initially.

Exit criteria: tampered, stale, wrong-action, wrong-user, and wrong-key
approvals are rejected in automated tests.

## Milestone 4 — opt-in lock-screen unlock

Goal: provide the Touch-ID-like desk workflow without unsafe typing.

- Store the user's login password only in Keychain through `zb-authd`.
- Add an explicit feature toggle.
- Obtain current macOS lock state from the Mac-local process.
- On a physical match, require a locked session, then send exactly one HID
  password transaction.
- Add a cooldown and failure timeout.

Exit criteria: no password is typed while the session is active; no password
crosses Pi/Mac control protocol or browser/relay path.

## Milestone 5 — PAM `sudo`

Goal: authorize `sudo` without typing a password.

- Implement and unit-test minimal `pam_zerobridge.so`.
- Implement peer-verified `~/.zerobridge/auth.sock` in `zb-authd`.
- Install only into `sudo_local` with safe password fallback.
- Add cancellation when the PAM client exits or Ctrl-C is received.
- Add a recovery/uninstall command that removes the configuration.

Exit criteria: valid fingerprint succeeds; denied/expired/unavailable requests
fall back to password as configured; invalid Pi approvals never succeed.

## Later milestones

Consider only after the above is stable:

- GUI authorization prompts;
- reviewed password-manager field injection;
- agent command approval overlay and process-bound grants;
- SSH signing using a separately designed key store;
- TOTP/API secret support;
- multi-host support.

Do not add a generic “recent fingerprint success” flag for these features.
Every new capability must define its own action binding and expiry.

## Verification checklist

- Rust: `cargo fmt --check`, `cargo clippy`, unit tests for framing/policy.
- macOS daemon: tests for pairing, signature verification, Keychain failure,
  lock-state uncertainty, and cancellation.
- PAM: test success, denial, timeout, daemon absent, Ctrl-C, and password
  fallback in a disposable local account.
- Hardware: repeat enrollment, match/no-match, sensor sleep/wake, power loss,
  malformed UART frames, and long-duration idle testing.
- Security: confirm no credentials/biometric payloads appear in logs or
  network captures.
