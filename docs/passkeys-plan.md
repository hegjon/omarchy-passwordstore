# Passkeys alongside passwords: a plan

Status: plan, not a feature (issue #4). Researched 2026-09-07; the links
are the sources, and "unknown" is written where nothing could be verified.

## What a passkey is, for this plugin

A passkey is a WebAuthn/FIDO2 *discoverable credential*: a key pair the
browser asks an authenticator to make for a site and later to sign with.
Nothing is pasted or typed, so the card's copy and type actions do not
apply. What a manager stores is the private key and the metadata the
protocol needs; what it does is answer the browser's
`authenticatorMakeCredential` / `authenticatorGetAssertion` calls.

## How a browser on Linux reaches a manager

Chromium and Firefox on Linux only see authenticators through the OS's raw
USB-HID transport (plus BLE/NFC/hybrid QR). There is no platform "passkey
provider" API as on Android, macOS or Windows. The community
[Credentials for Linux](https://github.com/linux-credentials) effort
(`libwebauthn`, `credentialsd`, a portal) has a Firefox 140+ extension and
a patched Firefox Flatpak, was presented at
[FOSDEM 2026](https://fosdem.org/2026/schedule/event/838A8N-credentials-for-linux-bringing-passkeys-to-linux/),
and is not in mainline Firefox or Chromium. So today the only route that
works with unmodified browsers is a **virtual authenticator**: a userspace
process that creates a HID device through `/dev/uhid`, which the kernel
exposes as `/dev/hidraw*` exactly as a real security key would be.

## Existing pieces

- [Passless](https://github.com/pando85/passless) (Rust, GPL-3.0) is a
  CTAP2 authenticator over uhid built on the author's
  [soft-fido2](https://github.com/pando85/soft-fido2) library, with a
  pluggable backend model and a **`pass` backend already implemented**
  (GPG-encrypted, git-synced), plus experimental TPM and filesystem
  backends. On AUR as `passless` / `passless-bin`. Its README says it is
  not yet validated for production and that client compatibility is an
  open issue; it needs only unprivileged `/dev/uhid` access.
- [softfido](https://github.com/ellerh/softfido) and
  [softauth](https://github.com/nmdanny/softauth): older, smaller,
  no `pass` integration.
- [fido2-hid-bridge](https://github.com/BryanJacobs/fido2-hid-bridge)
  (Python, MIT): not an authenticator but a uhid → PC/SC bridge; the same
  front-end pattern with a smartcard behind it. Names Firefox; Chromium
  unknown.
- None of them documents an external plugin protocol for the private-key
  operation; each calls its backend in-process. An IPC to the card would
  be ours to design.

## uhid on Arch

A user process needs read/write on `/dev/uhid` to create the device: a
udev rule such as `KERNEL=="uhid", SUBSYSTEM=="misc", GROUP="<group>",
MODE="0660"` and `uhid` in `/etc/modules-load.d/`; there is no standard
Arch group for it ([discussion](https://discuss.cachyos.org/t/change-group-for-dev-hidraw-and-dev-uhid-permanently/20529)).
The resulting hidraw node follows the usual security-key rules
([u2f-hidraw-policy](https://aur.archlinux.org/packages/u2f-hidraw-policy)),
so browsers need nothing new.

## The record

One entry per passkey, `passkeys/<rp id>/<user handle>`, encrypted like
everything else and synced the same way. Fields: COSE algorithm (ES256,
`-7`), the private key (PKCS#8, base64; it never leaves the store
unencrypted), rp id, credential id, user handle (opaque, ≤ 64 bytes), user
display name, sign counter (monotonic; many platform authenticators keep
it at 0, which the spec allows), flags (UP/UV/BE/BS), created stamp. CTAP2
allows one resident credential per user handle per rp id, so that path is
the natural key. The editor shows these read-only, the rp id as the name.

Protocol shape, for sizing: `makeCredential` takes rp, user, algorithms,
client-data hash, `rk=true`; it generates the key pair, stores the record
and returns an attestation object. `getAssertion` takes rp id (and an
optional allow list) plus the client-data hash; with no allow list it
enumerates the stored credentials for that rp id (a picker), performs user
verification, reports the counter and returns credential id, authenticator
data and signature
([CTAP 2.2](https://fidoalliance.org/specs/fido-v2.2-rd-20230321/fido-client-to-authenticator-protocol-v2.2-rd-20230321.html)).

## Moving passkeys elsewhere

The FIDO Alliance Credential Exchange Format (CXF) reached review draft in
March 2025 ([spec](https://fidoalliance.org/specs/cx/cxf-v1.0-rd-20250313.html));
the proposed-standard date differs between sources (unknown which is
authoritative). Apple ships CXF-based transfer in iOS/macOS 26; 1Password
and Bitwarden publish a Rust reference implementation
([crate](https://crates.io/crates/credential-exchange-format)). The
transport protocol (CXP, HPKE) was still being standardised in early 2026.
Export/import waits for that to settle.

## Recommended route and steps

Build on the virtual-authenticator route with Passless rather than a
CTAP2 stack of our own: it already has the uhid front end, the CTAP2
engine and a `pass` backend; what it lacks is the consent UI and a
hardening review.

1. Package or vendor `soft-fido2`/Passless; write the udev rule for
   `/dev/uhid`; confirm the hidraw node's permissions on a stock Omarchy.
2. Fix the record format above and make Passless's `pass` backend write
   it (or extend the backend), so a passkey is an ordinary vault entry
   that syncs with the rest.
3. Consent UI: a Quickshell card (the pinentry's shape) on every
   `makeCredential`/`getAssertion`: rp id, the account picker for
   resident-credential enumeration, and the existing GPG/pinentry flow as
   "user verification".
4. Test registration and sign-in against webauthn.io and a few real sites
   in Chromium and Firefox on Wayland; check the browser does not prefer
   the hybrid/QR path over the HID one.
5. Review Passless's code paths that touch key material before trusting it
   with real credentials; it says itself it is not production-validated.
6. Defer CXF/CXP import and export until the format is final; track
   `credentialsd` as a later, portal-based route.

Out of scope: hardware keys (they hold their own credentials) and the
browsers' built-in passkey stores.
