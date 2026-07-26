# Changelog

## Unreleased

- `Improv.Wifi.configure/3` no longer hardcodes `key_mgmt: :wpa_psk` for
  every non-empty password. SAE-only (WPA3-only) networks associated fine
  but always failed the 4-way handshake, since PSK auth was offered against
  an AP that only speaks SAE. `key_mgmt: :sae` (with `sae_password` and
  `ieee80211w: 2`, PMF being mandatory for WPA3) is now inferred from the
  target SSID's live scan flags, falling back to `:wpa_psk` when no scanned
  BSS is SAE-only, the SSID isn't in scan results (hidden network, aged
  out), or the scan lookup itself raises (#2).

## v0.1.1

Hardening release addressing the post-extraction security review.

- Submitted passwords are pre-validated in `Improv.command_action/1`
  (empty for open networks, or the WPA-PSK 8..63-byte rule) and rejected
  as `invalid_rpc` before reaching the Wi-Fi backend.
- Exception logs on the credential path are bounded
  (`printable_limit: 200`) so a raising Wi-Fi backend can't leak a
  submitted PSK into persisted logs.
- A raising `network_type:` connectivity probe now reads as online — the
  device stays disarmed (fail-closed) instead of crashing the
  `:one_for_all` group.
- Identify commands coalesce while one identify task is running (also
  serializing its physical side effects); scan commands are debounced
  (`scan_debounce_ms:`, default 5 s).
- A failed provision attempt no longer resets the session idle timer
  (failures are not meaningful advances).
- The adapter `Alias` is restored alongside `Pairable` when
  `RegisterAdvertisement` fails.
- RPC commands are ignored outside live-session states
  (defense-in-depth).
- CI/publish workflows pin GitHub Actions to commit SHAs.

## v0.1.0

Initial release, extracted from the Universal Proxy Nerves application
(hardware-validated on a Raspberry Pi 3 B+ against the Home Assistant
companion app).

- Improv-over-BLE protocol: submit Wi-Fi (`0x01`), identify (`0x02`),
  device info (`0x03`), scan networks (`0x04`); capabilities byte derived
  from configuration.
- BlueZ-over-D-Bus GATT server + LE advertisement (via the `bluez`
  library), mounted in `Bluez`'s `extra_children:` slot.
- Advertisement ServiceData in the spec's 6-byte/16-bit-key form — fits
  the 31-byte legacy advertising budget of BT 4.x controllers.
- Session security: no-connectivity arm gate (once per boot), idle
  timeout with meaningful-advance-only resets, absolute session cap,
  connect timeout with in-session retry.
- Optional VintageNet Wi-Fi backend (`Improv.Wifi`) and optional
  Phoenix.PubSub status broadcasts.
