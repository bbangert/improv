# Improv

[Improv-over-BLE](https://www.improv-wifi.com/) Wi-Fi provisioning for
Elixir/Nerves devices, built on [BlueZ over D-Bus](https://hex.pm/packages/bluez).

A device with no network connectivity advertises the Improv BLE service;
a provisioner (the Home Assistant companion app, improv-wifi.com, or any
Improv client) connects, optionally scans for networks, submits SSID +
password, and gets redirected to the device's web UI on the new network.

Implements the full Improv BLE protocol: submit Wi-Fi (`0x01`), identify
(`0x02`), device info (`0x03`), and scan networks (`0x04`), with the
capabilities byte derived from what you configure.

## Documentation

Start here once you're ready to go beyond the quickstart below:

- [Architecture guide](guides/architecture.md) — the supervision tree
  (why the group is `:one_for_all` and mounted last), the manager state
  machine, and the exported D-Bus surface.
- [Host integration guide](guides/host_integration.md) — the integration
  cookbook: every `Improv.Supervisor` option, the status/PubSub contract,
  the built-in Wi-Fi backend and how to replace it, and the
  vintage_net-is-optional story.
- [Protocol and security guide](guides/protocol.md) — the wire formats,
  the 31-byte legacy-advertising budget math, and the session security
  model that stands in for the Improv authorization handshake.

The core modules carry the reference detail: `Improv` (manager + every
option), `Improv.Protocol` (the codec), `Improv.GattServer` /
`Improv.Advert` (the exporters), `Improv.Wifi` (the backend).

## Requirements

- BlueZ ≥ 5.x with `bluetoothd` running on the system D-Bus (the usual
  [bluez](https://hexdocs.pm/bluez) Nerves/host setup) and a BLE-capable
  adapter.
- Optional: [`vintage_net`](https://hex.pm/packages/vintage_net) for the
  built-in Wi-Fi backend (`Improv.Wifi`); without it, inject your own
  scan/configure functions.
- Optional: [`phoenix_pubsub`](https://hex.pm/packages/phoenix_pubsub) for
  status broadcasts.

## Usage

Mount `Improv.Supervisor` in `Bluez`'s `extra_children:` slot, **appended
last** — under `Bluez`'s `:rest_for_one` strategy a `bluetoothd`/client
restart then rebuilds the Improv group (whose exporters hold now-stale D-Bus
registrations), while an Improv fault never disturbs the children before it:

```elixir
{Bluez,
 client: [...],
 extra_children: [
   {Improv.Supervisor,
    [
      # Connectivity probe for the arm gate. REQUIRED for provisioning to
      # ever activate: nil (the default) reads as online = never arm.
      network_type: &MyApp.Network.type/0,

      # BLE-visible name becomes "My Device <suffix>" (suffix = last 4 hex
      # of the device MAC). Or pass local_name: for the full string.
      name_prefix: "My Device",

      # Optional — Identify (0x02): do something physically observable.
      # Sets capability bit 0. Runs fire-and-forget off the manager loop.
      identify_fun: &MyApp.Identify.blink/0,

      # Optional — Device Info (0x03) strings. Sets capability bit 1.
      device_info: [
        firmware_name: "My Firmware",
        firmware_version: "1.2.3",
        hardware: "Raspberry Pi 3 Model B Plus",
        device_name: "My Device 507f"
      ],

      # Optional: pubsub: MyApp.PubSub for {:improv_status, _} broadcasts,
      # ifname: "wlan0" (default), timeout/cap overrides, …
    ]}
 ]}
```

`Improv.status/1` returns `%{state: fsm, error: atom | nil}` and works on any
target — it answers a disarmed shape when the subsystem isn't running.

## Security model

The Improv authorization handshake is **not** used (the GATT characteristics
are cleartext); the session is instead bounded by:

- **No-connectivity arm gate**: the subsystem arms (exports the GATT app +
  advertisement) only when the device boots with no network connectivity —
  and only once per boot. A device that's already online never exposes the
  provisioning surface. The boot connectivity read races DHCP/link bring-up,
  so arming re-checks after a 20 s grace period.
- **Idle timeout** (5 min): reset only on a *meaningful* state advance
  (first client connect, a valid submit) — never on arbitrary client
  activity, so a flooding peer cannot hold the session open.
- **Absolute session cap** (15 min): disarms regardless of activity.
- **Connect timeout** (30 s): a submit that never reaches full `:internet`
  connectivity reverts to AUTHORIZED with `unable_to_connect`, allowing a
  retry within the session.
- The adapter is made non-pairable for the session (no bond is needed for
  cleartext characteristics) and restored on teardown.

## ServiceData and legacy (BT 4.x) controllers

The advertisement carries the spec's 6-byte ServiceData
`[state, capabilities, 0 ×4]` keyed by the **16-bit** `"4677"` UUID. That
form totals exactly 31 bytes alongside the mandatory Flags and the 128-bit
service UUID — the entire legacy advertising budget, with the local name
falling to the scan response. Controllers without LE Extended Advertising
(e.g. a Raspberry Pi 3's BCM4345C0) reject anything larger: a 128-bit-keyed
ServiceData was hardware-tested and refused by `bluetoothd` with "Invalid
Parameters". The payload is static (state frozen at AUTHORIZED): BlueZ reads
the advertisement properties once at registration, and clients read live
state/capabilities from the GATT characteristics after connecting.

## Installation

```elixir
def deps do
  [
    {:improv, "~> 0.1"}
  ]
end
```
