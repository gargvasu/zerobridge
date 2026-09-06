# Security model and non-goals

## Security claim

This feature can claim: **a paired Pi observed a locally matched fingerprint
before approving a bounded ZeroBridge action.**

It must not claim: “this is Apple Touch ID,” “the Pi is a secure element,” or
“a compromised Pi cannot control the Mac.”

## Trust boundaries

```text
fingerprint sensor     Pi Zero                 macOS
template flash    ->   Linux/pi-agent   ->     zb-authd/PAM/Keychain
match result           signing policy          OS authorization decision
```

- The sensor owns biometric templates and matching.
- The Pi owns the USB keyboard and is therefore a high-trust device.
- The Mac owns account passwords in Keychain and decides authorization policy.
- The phone/PWA is a remote-control client, not the fingerprint authority.

## Threats and controls

| Threat | Required control |
|---|---|
| Replayed approval | Random 256-bit nonce; request ID and nonce consumed once |
| Forged Pi response | Persistent paired public keys; signature over every approval |
| Approval used for another action | Sign user, service, action, command digest, and expiry |
| Network attacker on USB/Wi-Fi | Pairing; authenticated requests; do not rely on source IP alone |
| Sensor template exposure | Use sensor-local matching; prohibit image/template export |
| Unintended typing onto desktop | Check locked state; one-shot transaction; fail closed |
| Stolen phone browser session | Require Pi fingerprint for fingerprint-gated actions |
| Stolen Pi | Treat as sensitive hardware; protect access and enrollment |
| Root compromise of Pi | Out of scope for preventing input injection; root controls HID |
| Exposed UART wires | Keep sensor wiring inside enclosure |

## Pi compromise is a hard limit

The Pi Zero is the USB keyboard. Root access can write arbitrary HID reports,
bypass the sensor driver, modify the daemon, and impersonate approvals.

No software protocol running solely on that Pi can prevent this. A sensor
improves presence verification and protects biometric templates from ordinary
Pi filesystem access; it does not make the Pi a hardware security key.

If resistance to Pi compromise is a future product requirement, move signing
authority into a separate secure MCU/secure element that will not sign without
an independently validated fingerprint event. That becomes a different
hardware architecture.

## Sensor limitations

UART fingerprint modules are not Secure Enclave-class components:

- vendor matcher and liveness claims are difficult to independently audit;
- UART match indications may be physically spoofed by someone who opens the
  enclosure;
- sensor template capacity and false-match thresholds vary by module;
- threshold configuration must be explicit and tested with enrolled and
  unenrolled fingers.

Use a conservative score/security level, validate returned template IDs against
the enrolled allowlist, and require multi-capture enrollment.

## Data handling

Never persist or log:

- raw fingerprint images, minutiae, templates, or sensor password;
- macOS passwords outside Keychain;
- unencrypted private keys in repo/config/logs;
- plaintext command secrets or `imk://`-style values;
- challenge nonces or signatures in normal logs.

Log only timestamp, local account, action/service class, result, and a
correlation ID that cannot be used as an approval token.

## Enrollment policy

Enrollment changes the biometric trust base and therefore requires:

1. a deliberate local physical action (button or physical Pi console);
2. an existing authorized fingerprint where at least one exists;
3. guided multi-capture enrollment;
4. immediate template-ID allowlist update;
5. explicit confirmation before deletion/reset;
6. a documented local recovery path if every enrolled finger is unavailable.

Remote PWA-only enrollment and deletion are out of scope.
