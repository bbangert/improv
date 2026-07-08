# Changelog

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
