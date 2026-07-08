# Protocol and security model

What actually goes over the air, and why the session is bounded the way
it is. The wire formats are locked against
[improv-wifi.com/ble](https://www.improv-wifi.com/ble/) and the reference
SDKs (`improv-wifi/sdk-ble-js`, ESPHome's `esp32_improv` component); all
encoding/decoding lives in the pure `Improv.Protocol` codec.

## Service and characteristics

One primary service (`00467768-6228-2272-4663-277478268000`) with five
characteristics, `…8001`–`…8005`:

| Characteristic | Flags | Carries |
| -------------- | ----- | ------- |
| current-state | read, notify | one bare byte |
| error-state | read, notify | one bare byte |
| rpc-command | write, write-without-response | framed commands |
| rpc-result | read, notify | framed results |
| capabilities | read | one bare byte |

Everything is **cleartext — no encrypt flags**: security comes from the
session model below, not from BLE pairing (the adapter is made
non-pairable for the session so provisioners aren't nudged to bond).

## Frames

The RPC characteristics carry framed packets:

```
[command_id] [data_length] [data …] [checksum]
```

`checksum` is the low byte of the sum of every preceding byte. Malformed
structure or a checksum mismatch pushes the `invalid_rpc` error; a
well-formed frame for an unimplemented command pushes `unknown_command`.

| Command | Data | Result |
| ------- | ---- | ------ |
| `0x01` submit Wi-Fi | `[ssid_len][ssid][pwd_len][pwd]` (`pwd_len 0` = open network) | on success, one result carrying the redirect URL |
| `0x02` identify | none | **none** (the device just does something visible) |
| `0x03` device info | none | one result: firmware name, firmware version, hardware variant, device name |
| `0x04` scan networks | none | one result **per network** (`[ssid, rssi, "YES"/"NO"]`), then an empty terminator frame |

Result data is a sequence of 1-byte-length-prefixed strings — no count
byte, matching the sequential decode in `sdk-ble-js` (hardware-validated
against the Home Assistant app).

## States, errors, capabilities

Current-state bytes: `0x01` authorization-required (never sent — see
below), `0x02` authorized, `0x03` provisioning, `0x04` provisioned.
`:disarmed`, `:advertising` and `:connected` all present as AUTHORIZED;
the distinction is internal.

Error bytes: `0x00` none, `0x01` invalid RPC, `0x02` unknown command,
`0x03` unable to connect, `0x04` not authorized, `0xFF` unknown.

Capabilities: bit 0 identify (`0x01`), bit 1 device-info (`0x02`), bit 2
scan-wifi (`0x04`, always set — and what makes improv-wifi.com show the
network dropdown), bit 3 hostname (unsupported). The byte is derived from
configuration — see the Host integration guide.

## The advertisement and the 31-byte budget

A legacy (BT 4.x) advertising PDU holds 31 bytes. The advertisement
packs, exactly:

```
Flags AD                    3 bytes
ServiceData AD (16-bit key) 1 + 1 + 2 + 6 = 10 bytes
ServiceUUIDs AD (128-bit)   1 + 1 + 16   = 18 bytes
                            ───────────────
                            31 bytes
```

so `LocalName` falls to the scan-response packet. The ServiceData is the
spec's 6-byte payload `[current_state, capabilities, 0x00 ×4]` keyed by
the **16-bit** `"4677"` UUID. Two alternatives were rejected on real
hardware grounds:

- Keying by the 128-bit UUID (~24-byte AD) — `bluetoothd` refuses the
  oversized advert with "Invalid Parameters" on controllers without LE
  Extended Advertising (hardware-tested on a Pi 3's BCM4345C0).
- The ESP32 reference's 8-byte `"PM…"` payload — 33 bytes total, also
  over budget next to the 128-bit UUID.

The payload is **static at registration** (state frozen at AUTHORIZED):
BlueZ reads `LEAdvertisement1` properties once at
`RegisterAdvertisement`, a live update would need re-registration churn,
and legacy controllers stop advertising while a client is connected —
which is when every post-AUTHORIZED state occurs. Clients read live
state and capabilities from the GATT characteristics after connecting;
`Improv.Advert.set_state/2` is deliberately a no-op.

## Session security model

The Improv authorization handshake (`0x01` authorization-required, the
authorize command) is **not** used — the session is bounded instead:

- **No-connectivity arm gate.** The GATT app and advertisement are only
  exported when the device boots with no network connectivity, and at
  most once per boot: connectivity dropping later never re-arms (that
  requires a reboot), and a session ending (timeout or provisioned)
  disarms for good. Because the boot connectivity read races DHCP/link
  bring-up, an offline reading is re-checked after a 20 s grace before
  arming — otherwise every Ethernet boot would spuriously advertise.
- **Idle timeout, meaningful-advance resets only** (5 min). The timer
  resets on the first client connect and on a valid submit — never on
  arbitrary client activity, so a flooding peer cannot hold the session
  open by poking characteristics.
- **Absolute session cap** (15 min). Armed once at arm time and never
  reset, so repeated valid submits can't extend the session forever.
- **Connect timeout** (30 s). A submit whose interface never reaches
  full `:internet` reverts to AUTHORIZED with `unable_to_connect`; the
  provisioner can retry within the session with corrected credentials.
- **Provisioned hold** (10 s), just long enough for the client to read
  the redirect-URL result, then teardown.

The threat this addresses: a provisioning surface that accepts cleartext
credentials must only exist when the device is genuinely unconfigured
(offline boot), must disappear on its own (timers), and must never let a
nearby peer keep it open indefinitely (reset rule + cap).
