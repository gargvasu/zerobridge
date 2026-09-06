# macOS integration

## Authentication surfaces

macOS has separate paths for different prompts. Treat them separately.

| Surface | Planned mechanism | Password needed? | Limitation |
|---|---|---:|---|
| Locked running session | Verified match → USB HID typing | Yes, Keychain | Not native Touch ID |
| `sudo` | `pam_zerobridge.so` → `zb-authd` → Pi challenge | No | PAM services only |
| PAM-backed authorization dialog | Same PAM flow, possibly a GUI bridge | No | Must test per service/release |
| App-specific password sheet | Accessibility credential injection | Yes, Keychain | Later milestone; app allowlist required |
| FileVault / boot login | Not supported by fingerprint | Password only | No user daemon at preboot |
| Apple Pay / App Store Touch ID / `LAContext` | Not supported | N/A | Secure Enclave-only APIs |

## Screen unlock

The macOS lock screen does not provide a general third-party biometric API.
The practical mechanism is the same one used by dedicated external
authenticator projects: after a verified fingerprint event, enter the user's
existing login password into the lock-screen field.

### Required controls

- Store the password only in macOS Keychain, scoped to the logged-in user.
- Do not send the password to the Pi, browser, or WebSocket relay.
- Check that the session is locked immediately before typing.
- Use a short-lived unlock transaction: one match, one password injection.
- Abort on uncertainty: active desktop, unknown screen state, changed user, or
  unavailable Keychain item.
- Include a feature toggle and a visible indicator so a finger touch does not
  unexpectedly type a password.

The existing ZeroBridge `go-server` unlock endpoint is not suitable as the
final fingerprint-unlock design: it accepts a plaintext password supplied by
the browser and passes it to the Pi. Migrate fingerprint unlock to the
Mac-local daemon before enabling it.

## PAM for sudo

Start by supporting only the currently logged-in local user and `sudo`.

### Installation target

On current macOS versions, use `/etc/pam.d/sudo_local` where available. The
module line must be placed before password fallback and use a policy that
allows password fallback when the Pi is unavailable:

```text
auth       sufficient       pam_zerobridge.so
```

The exact PAM configuration must be detected and backed up by the installer.
Never overwrite Apple-managed `/etc/pam.d/sudo` blindly. Include an uninstall
path and a recovery command that removes the module line.

### Socket boundary

`pam_zerobridge.so` connects to a Unix socket owned by the authenticated user,
for example `~/.zerobridge/auth.sock`.

The daemon must:

- create the directory and socket with `0700` and `0600` permissions;
- call `getpeereid()` (or equivalent) and accept only root or that user;
- bind an absolute, user-home-derived socket path;
- use bounded reads and a finite timeout;
- cancel the Pi challenge if PAM disconnects or the user presses Ctrl-C.

The PAM module must not log passwords, nonces, signatures, or sensor template
IDs. It should return:

- `PAM_SUCCESS` for a valid action-bound fingerprint approval;
- `PAM_IGNORE` when disabled/unavailable, allowing normal password fallback;
- `PAM_AUTH_ERR` for a completed rejection or invalid response.

## Agent and command approvals

An `imk run --agent`-style workflow is feasible as a future macOS CLI:

1. CLI serializes the exact command, working directory, environment-secret
   references, and a random nonce to `zb-authd`.
2. Daemon renders a local confirmation overlay.
3. Pi fingerprint approval signs a digest of that exact request.
4. Daemon permits the waiting child only for the approved digest and expiry.
5. Reject, timeout, disconnect, or mismatch terminates the child.

Do not make a generic “fingerprint matched recently” boolean available to
arbitrary processes. Bind approval to one process/action instead.

## Optional credential injection

For a later macOS password-manager/app-login feature:

- use Keychain for each secret;
- limit injection to a user-reviewed application/bundle-ID allowlist;
- require a verified match for every fill;
- target only an expected secure text field;
- record minimal audit metadata;
- never claim it is equivalent to Touch ID or bypasses protected Apple APIs.
