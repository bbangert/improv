defmodule Improv.Supervisor do
  @moduledoc """
  Supervises the Improv provisioning processes as a `:one_for_all` group.

  The children are mutually dependent — the `Improv` manager registers and drives
  the `GattServer` + `Advert` D-Bus exporters (off-loop via the `Task.Supervisor`)
  — so a crash of any one must restart all of them together. Under the parent
  `Bluez` supervisor's `:rest_for_one`, the manager (started last)
  crashing would otherwise leave `GattServer`/`Advert` running: the cleartext GATT
  app + advertisement would stay exported with no session timers or disarm logic.

  Restarting the whole group instead drops the exporters' own `rebus` connections,
  which makes `bluetoothd` auto-unregister the GATT application + advertisement,
  and the manager re-evaluates connectivity from a clean slate.

  ## Mounting contract

  Improv is a *consumer* of the `Bluez` subtree, not part of it: mount this
  supervisor in `Bluez`'s `extra_children:` slot, appended **last**. Under the
  `Bluez` parent's `:rest_for_one` strategy that position means a
  `bluetoothd`/`Bluez.Client` restart rebuilds the whole Improv group (whose
  exporters hold now-stale D-Bus registrations), while an Improv fault never
  disturbs anything before it — the host's scanning/GATT or audio stacks.
  The child spec's opts are also where the host passes the manager's options
  (`pubsub:`, `network_type:`, `ifname:`, `identify_fun:`, `device_info:`, …)
  and the advert branding (`name_prefix:` / `local_name:`):

      {Bluez,
       client: [...],
       extra_children: [
         {Improv.Supervisor,
          [
            pubsub: MyApp.PubSub,
            network_type: &MyApp.Network.type/0,
            name_prefix: "My Device",
            identify_fun: &MyApp.Identify.blink/0,
            device_info: [
              firmware_name: "My Firmware",
              firmware_version: "1.2.3",
              hardware: "Raspberry Pi 3 Model B Plus",
              device_name: "My Device 507f"
            ]
          ]}
       ]}
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  # `opts` are the Improv manager's opts (`pubsub:`, `network_type:`,
  # `ifname:`, `identify_fun:`, `device_info:`, …) plus the advert branding
  # (`name_prefix:` / `local_name:`), passed in this supervisor's child spec
  # (see bluez_spec/0).
  def init(opts) do
    {advert_opts, manager_opts} = Keyword.split(opts, [:local_name, :name_prefix])

    # Derived ONCE so the GATT capabilities characteristic and the
    # advertisement's ServiceData byte can never disagree.
    capabilities =
      Improv.Protocol.capabilities(
        identify?: Keyword.get(opts, :identify_fun) != nil,
        device_info?: Keyword.get(opts, :device_info) != nil
      )

    children = [
      # Runs the re-entrant Register{Application,Advertisement} calls off the
      # GenServer loops (they call back into our own handlers).
      {Task.Supervisor, name: Improv.TaskSupervisor},
      # Exporters first — the manager registers and drives them on arm.
      {Improv.GattServer, capabilities: capabilities},
      {Improv.Advert, [capabilities: capabilities] ++ advert_opts},
      {Improv, manager_opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
