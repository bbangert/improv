# Host integration

Everything the library needs from your application flows through
`Improv.Supervisor`'s opts. This guide is the integration cookbook: the
full option surface, the status/PubSub contract, and what the built-in
Wi-Fi backend does versus what you can inject.

The running example is a Nerves ESPHome-style proxy (the application the
library was extracted from), but nothing here is specific to it.

## Wiring it up

Mount the supervisor in `Bluez`'s `extra_children:` slot, appended last
(see the Architecture guide for why):

```elixir
{Bluez,
 client: [...],
 gatt: [...],
 extra_children: [
   {Improv.Supervisor,
    [
      # ── arm gate (REQUIRED for provisioning to ever activate) ──────
      # 0-arity fun; :disconnected = offline. nil (the default) reads as
      # online, so an unconfigured host NEVER arms — fail-closed.
      network_type: &MyApp.System.network_type/0,

      # ── branding ────────────────────────────────────────────────────
      # BLE-visible name becomes "My Device <suffix>", suffix = last 4
      # hex of the device MAC (hostname tail off-target). Or pass
      # local_name: "exact string" to skip suffixing.
      name_prefix: "My Device",

      # ── optional commands (capability bits derive from these) ──────
      # Identify (0x02): something physically observable; run
      # fire-and-forget under Improv.TaskSupervisor, may block/sleep.
      identify_fun: &MyApp.Identify.blink_led/0,
      # Device Info (0x03): static strings, resolved when you build the
      # child spec.
      device_info: [
        firmware_name: "My Firmware",
        firmware_version: "1.2.3",
        hardware: "Raspberry Pi 3 Model B Plus",
        device_name: "My Device 507f"
      ],

      # ── plumbing (all optional) ─────────────────────────────────────
      pubsub: MyApp.PubSub,       # {:improv_status, _} broadcasts; nil = no-op
      ifname: "wlan0",            # interface being provisioned (default)
      scanner: Bluez.Client       # gets suspend_scan/resume_scan casts (default)
    ]}
 ]}
```

`Improv.Advert.device_suffix/0` is public so the host can build other
device-facing strings that match the advertised name — the example app
uses it for `device_info:`'s `device_name`.

Timer overrides (`timeout_ms`, `session_cap_ms`, `connect_timeout_ms`,
`boot_grace_ms`, `provisioned_hold_ms`) exist mainly for tests; the
defaults implement the security model in the README.

## Capabilities are derived, not configured

There is no `capabilities:` option. The supervisor derives
the byte once — scan-wifi always (built in), identify iff `identify_fun:`
is set, device-info iff `device_info:` is set — and threads the same
value to the GATT capabilities characteristic and the advertisement's
ServiceData, so the two can never disagree. Configure both callbacks and
clients see `0x07`.

A command whose capability bit is off is rejected with the Improv
`unknown_command` error if a non-compliant client sends it anyway.

## Status and PubSub

`Improv.status/1` returns `%{state: fsm, error: atom | nil}` and is safe
to call on any target: it answers `%{state: :disarmed, error: nil}` when
the subsystem isn't running (non-BT target, subtree down) instead of
raising. Note what the `catch :exit` there swallows — a wedged manager
also renders as disarmed rather than crashing the caller.

With a `pubsub:` configured, every state change and pushed error
broadcasts

```elixir
{:improv_status, %{state: fsm, error: atom | nil}}
```

on the `"bluetooth:improv"` topic (`Improv.status_topic/0`). A LiveView
status card subscribes on mount and re-renders on the message; the FSM
states map to display as: `:disarmed` (idle), `:advertising`/`:connected`
(window open — all present as AUTHORIZED to BLE clients),
`:provisioning`, `:provisioned`.

## The Wi-Fi backend

`Improv.Wifi` is the default `wifi:` implementation, built on VintageNet
(an optional dependency — see below):

- `scan_networks/1` reads the live `access_points` property that
  `wpa_supplicant` keeps refreshed, **not** `VintageNetWiFi.quick_scan/1`
  (whose fresh-scan + 2 s sleep lands in the empty mid-scan window on
  hardware), and kicks an async `VintageNet.scan/1` for the next call.
- `configure/3` applies a WPA-PSK (or open, for an empty password) DHCP
  config to the interface with `persist: true` semantics — the
  credentials survive the reboot.
- `redirect_url/1` builds `http://<ip>/` from the interface's first IPv4
  address for the post-provision redirect.

Every function takes `ifname:` in its trailing opts (the manager threads
its own `ifname:` automatically) and injectable `vintage_get:` /
`scan_trigger:` / `configure_fn:` funs.

To replace the backend entirely, pass `wifi: MyBackend` — any module
with the same three functions (each accepting the trailing opts list).
The manager calls it through a rescue, so a raising backend degrades to
`wifi_unavailable` instead of crashing the session.

## vintage_net is optional — and `runtime: false`

The dependency is declared `optional: true, runtime: false`:

- **optional** — hosts that inject a custom backend never pull it.
- **runtime: false** — this only affects the library's own dev/test
  runs: started on a host machine, vintage_net writes `/etc/resolv.conf`.
  It does **not** propagate to consumers: a Nerves app depends on
  vintage_net directly, and that declaration governs its startup.

All VintageNet access in the library is `Code.ensure_loaded?`-guarded
and rescued, so the modules load and the decision logic is testable with
the dependency absent, present-but-stopped, or running.
