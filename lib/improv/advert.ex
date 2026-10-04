defmodule Improv.Advert do
  @moduledoc """
  Exports an `org.bluez.LEAdvertisement1` object and registers it with the
  adapter's `org.bluez.LEAdvertisingManager1`, so the device advertises the
  Improv service while provisioning is armed.

  Same export+dispatch shape as `Bluez.Agent` (own `rebus`
  connection, `set_method_handler`, reply to inbound calls, register off-loop in
  a `Task`). The advertisement is a *single* read-only object with a `Release()`
  method BlueZ calls when it drops the advert.

  ## What we advertise

    * `Type` = `"peripheral"` (connectable),
    * `ServiceUUIDs` = `[improv service uuid]` (128-bit),
    * `ServiceData` = the spec's 6-byte payload keyed by the 16-bit `"4677"`
      UUID (see below),
    * `LocalName` = the device name (falls to the scan-response packet),
    * `Discoverable` = true.

  ## ServiceData and the 31-byte legacy-advertising budget

  The 128-bit service UUID consumes 18 of the 31-byte legacy budget, and the
  rpi3 controller (BCM4345C0, BT 4.x) has no LE Extended Advertising. A June
  2026 attempt keyed ServiceData by the **128-bit** UUID (~24-byte AD) made
  `bluetoothd` reject the advert with "Invalid Parameters" (HW-found on rpi3).
  The spec's form — 6-byte payload `[state, capabilities, 0 ×4]` keyed by the
  **16-bit** `"4677"` UUID — totals exactly 31 bytes alongside Flags + the
  128-bit ServiceUUIDs, so it fits. It is **static at registration** (state
  frozen at `:authorized`): BlueZ reads LEAdvertisement1 properties once at
  RegisterAdvertisement, dynamic updates would need re-registration churn,
  and legacy controllers stop advertising while a client is connected — which
  is when all post-`:authorized` states occur. Clients read live state and
  capabilities from the GATT characteristics after connecting (improv-wifi.com
  and the HA app both do), so nothing is lost. `set_state/2` is therefore a
  no-op, kept only so the manager's transitions stay uniform.
  """

  use GenServer
  require Logger

  # VintageNet is target-only; device_suffix/0 reads a MAC through it defensively.
  @compile {:no_warn_undefined, VintageNet}

  alias Bluez.{DBus, DevicePath}
  alias Improv.Protocol

  @props_iface "org.freedesktop.DBus.Properties"
  @introspect_iface "org.freedesktop.DBus.Introspectable"
  @adv_iface "org.bluez.LEAdvertisement1"
  @adv_mgr_iface "org.bluez.LEAdvertisingManager1"

  @adv_path "/org/improv/advert0"

  @register_timeout_ms 10_000

  @doc "Object path the LEAdvertisement1 object is exported at."
  @spec adv_path() :: String.t()
  def adv_path, do: @adv_path

  # ── public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Register the advertisement with BlueZ (idempotent; runs off-loop)."
  @spec register(GenServer.server()) :: :ok
  def register(server \\ __MODULE__), do: GenServer.cast(server, :register)

  @doc "Unregister the advertisement (idempotent)."
  @spec unregister(GenServer.server()) :: :ok
  def unregister(server \\ __MODULE__), do: GenServer.cast(server, :unregister)

  @doc "Update the advertised current-state (atom from `Protocol`)."
  @spec set_state(GenServer.server(), atom()) :: :ok
  def set_state(server \\ __MODULE__, state) when is_atom(state) do
    GenServer.cast(server, {:set_state, state})
  end

  # ── pure props / introspection (host-tested) ──────────────────────────────

  @doc """
  Build the `LEAdvertisement1` property list. Pure.

  `ServiceData` carries the spec's 6-byte payload `[current_state,
  capabilities, 0 ×4]` keyed by the 16-bit `"4677"` UUID — the only form that
  fits the 31-byte legacy budget next to the 128-bit ServiceUUIDs (see the
  moduledoc for the June 128-bit-keyed rejection). The state byte is frozen
  at `:authorized`; `capabilities` MUST be the same derived byte the GATT
  capabilities characteristic serves (the supervisor derives it once).
  `LocalName` falls to the scan-response packet.
  """
  @spec advertisement_props(String.t(), binary()) :: list()
  def advertisement_props(local_name, capabilities \\ Protocol.capabilities()) do
    [
      {"Type", {"s", "peripheral"}},
      {"ServiceUUIDs", {"as", [Protocol.service_uuid()]}},
      {"ServiceData", {"a{sv}", [{"4677", {"ay", service_data(capabilities)}}]}},
      {"LocalName", {"s", local_name}},
      {"Discoverable", {"b", true}}
    ]
  end

  # The spec's 6-byte ServiceData payload: [state, capabilities, reserved ×4],
  # static at registration (we always advertise AUTHORIZED — see set_state/2).
  defp service_data(<<caps>>) do
    <<state>> = Protocol.encode_state(:authorized)
    [state, caps, 0, 0, 0, 0]
  end

  @doc "Introspection XML for the advertisement object. Pure."
  @spec introspect_xml(String.t()) :: String.t()
  def introspect_xml(path) do
    interfaces = if path == @adv_path, do: ~s(<interface name="#{@adv_iface}"/>), else: ""

    ~s(<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">\n<node>#{interfaces}</node>)
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    case get_conn(opts) do
      {:ok, conn} ->
        Bluez.Rebus.set_method_handler(conn, self())
        conn_ref = Process.monitor(conn)

        state = %{
          conn: conn,
          conn_ref: conn_ref,
          local_name:
            Keyword.get_lazy(opts, :local_name, fn ->
              default_local_name(Keyword.get(opts, :name_prefix, "Improv"))
            end),
          # Derived once by the supervisor so it matches the GATT
          # capabilities characteristic.
          capabilities: Keyword.get(opts, :capabilities, Protocol.capabilities()),
          task_sup: Keyword.get(opts, :task_supervisor, Improv.TaskSupervisor),
          registered?: false
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:dbus_connect_failed, reason}}
    end
  end

  defp get_conn(opts) do
    case Keyword.get(opts, :conn) do
      nil -> Bluez.Rebus.connect(:system)
      conn when is_pid(conn) -> {:ok, conn}
    end
  end

  # Friendly name "<prefix> <suffix>" — the prefix comes from the `name_prefix:`
  # opt (host brand, e.g. "Universal Proxy"; defaults to "Improv"), or pass a
  # full `local_name:` to skip suffixing entirely. The suffix is the last 4 hex
  # of the device's MAC (eth0 preferred, else wlan0) — stable, device-unique, and
  # what the Nerves hostname is itself derived from (eth0 b8:27:eb:07:50:7f →
  # "507f"). Read directly from the MAC (not parsed from the hostname, which a
  # rename could change). VintageNet is host-guarded; falls back to the hostname
  # tail off-target / in tests. (Do NOT use Nerves.Runtime.serial_number here —
  # calling it in the host test VM triggers an uncatchable reboot/shutdown.)
  defp default_local_name(prefix), do: "#{prefix} #{device_suffix()}"

  @doc """
  The short device-unique suffix used in the default local name: last 4 hex
  of the device MAC, falling back to the hostname tail. Public so hosts can
  build other device-facing strings (e.g. Device Info's device name) that
  match the advertised BLE name.
  """
  @spec device_suffix() :: String.t()
  def device_suffix, do: mac_suffix() || hostname_suffix()

  # Rescued: with vintage_net as an optional dep the module can be LOADED but
  # its app not STARTED (host tests, early boot) — VintageNet.get then raises
  # instead of returning nil, and the hostname fallback must still win.
  defp mac_suffix do
    if Code.ensure_loaded?(VintageNet) do
      Enum.find_value(["eth0", "wlan0"], &iface_mac_suffix/1)
    end
  rescue
    _ -> nil
  end

  # Deliberate apply/3: vintage_net is optional, so a literal remote call would
  # warn "VintageNet.get/1 is undefined" when compiled without it.
  defp iface_mac_suffix(iface) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(VintageNet, :get, [["interface", iface, "mac_address"]]) do
      mac when is_binary(mac) and mac != "" ->
        mac |> String.replace(":", "") |> String.slice(-4, 4)

      _ ->
        nil
    end
  end

  defp hostname_suffix do
    {:ok, host} = :inet.gethostname()
    host |> List.to_string() |> String.split("-") |> List.last()
  end

  @impl GenServer
  def handle_cast(:register, %{registered?: true} = state), do: {:noreply, state}

  def handle_cast(:register, state) do
    # Optimistic registered?, healed back to false by {:register_result,
    # {:error, _}} if it actually failed, so a later register/1 retries.
    conn = state.conn
    name = state.local_name
    parent = self()
    run_task(state, fn -> send(parent, {:register_result, do_register(conn, name)}) end)
    {:noreply, %{state | registered?: true}}
  end

  def handle_cast(:unregister, %{registered?: false} = state), do: {:noreply, state}

  def handle_cast(:unregister, state) do
    conn = state.conn
    run_task(state, fn -> do_unregister(conn) end)
    {:noreply, %{state | registered?: false}}
  end

  # No-op: current-state isn't carried in the advertisement (31-byte legacy AD
  # limit on BT 4.x — see advertisement_props/1). Kept so the manager's transition
  # calls stay uniform; clients read state from the current-state characteristic.
  def handle_cast({:set_state, _state_atom}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:dbus_call, %Bluez.Rebus.Message{} = msg}, state) do
    {:noreply, dispatch_method_call(msg, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_ref: ref} = state) do
    {:stop, {:dbus_connection_down, reason}, state}
  end

  def handle_info({:register_result, {:ok, _}}, state), do: {:noreply, state}

  def handle_info({:register_result, {:error, _reason}}, state) do
    {:noreply, %{state | registered?: false}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── registration (outbound, off-loop) ─────────────────────────────────────

  # Run an outbound D-Bus task off the GenServer loop. The bare-Task fallback
  # inside Improv.Tasks matters here: without it the {:register_result, _}
  # heal would never arrive and registered? would stick at true.
  defp run_task(%{task_sup: sup}, fun), do: Improv.Tasks.run(sup, fun, "Improv.Advert")

  defp do_register(conn, local_name) do
    # Friendly post-connect GAP name (char 0x2A00 reflects Adapter1.Alias; default
    # is "BlueZ <ver>"), and make the adapter non-pairable for the session so the
    # provisioner isn't nudged to bond (the chars are cleartext — no bond needed).
    # Capture the current Alias first so a failed registration can restore it;
    # best-effort — if the Get fails we restore to "" and BlueZ falls back to
    # the system name (its own default).
    prev_alias = get_adapter_alias(conn)
    set_adapter_prop(conn, "Alias", {"s", local_name})
    set_adapter_prop(conn, "Pairable", {"b", false})
    log_advertising_slots(conn)

    case DBus.call(
           conn,
           DevicePath.adapter_path(),
           @adv_mgr_iface,
           "RegisterAdvertisement",
           "oa{sv}",
           [@adv_path, []],
           @register_timeout_ms
         ) do
      {:ok, _} = ok ->
        Logger.info("Improv.Advert: registered advertisement at #{@adv_path}")
        ok

      {:error, "org.bluez.Error.AlreadyExists"} ->
        Logger.debug("Improv.Advert: advertisement already registered")
        {:ok, :already}

      {:error, reason} = err ->
        Logger.error("Improv.Advert: RegisterAdvertisement failed: #{inspect(reason)}")
        # The advert never went up, so undo the adapter props we set above —
        # otherwise the adapter is stuck non-pairable, wearing our alias, for
        # the rest of the boot.
        set_adapter_prop(conn, "Pairable", {"b", true})
        set_adapter_prop(conn, "Alias", {"s", prev_alias || ""})
        err
    end
  end

  # Current org.bluez.Adapter1.Alias, or nil if unreadable (best-effort).
  defp get_adapter_alias(conn) do
    case DBus.call(
           conn,
           DevicePath.adapter_path(),
           @props_iface,
           "Get",
           "ss",
           ["org.bluez.Adapter1", "Alias"]
         ) do
      {:ok, [{_sig, current}]} when is_binary(current) -> current
      _ -> nil
    end
  end

  defp do_unregister(conn) do
    # Restore the adapter's default pairable state on teardown.
    set_adapter_prop(conn, "Pairable", {"b", true})

    case DBus.call(
           conn,
           DevicePath.adapter_path(),
           @adv_mgr_iface,
           "UnregisterAdvertisement",
           "o",
           [@adv_path],
           @register_timeout_ms
         ) do
      {:ok, _} -> Logger.info("Improv.Advert: unregistered advertisement")
      {:error, reason} -> Logger.debug("Improv.Advert: unregister: #{inspect(reason)}")
    end
  end

  # Set an org.bluez.Adapter1 property on the adapter (best-effort).
  defp set_adapter_prop(conn, prop, variant) do
    DBus.call(
      conn,
      DevicePath.adapter_path(),
      @props_iface,
      "Set",
      "ssv",
      ["org.bluez.Adapter1", prop, variant]
    )
  end

  # Best-effort visibility into adapter advertising-slot availability; we still
  # attempt registration and let BlueZ error if no slot is free.
  defp log_advertising_slots(conn) do
    with {:ok, [{_sig, supported}]} <- adv_mgr_prop(conn, "SupportedInstances"),
         {:ok, [{_sig2, active}]} <- adv_mgr_prop(conn, "ActiveInstances") do
      Logger.debug("Improv.Advert: advertising slots #{active}/#{supported} in use")
    else
      _ -> :ok
    end
  end

  defp adv_mgr_prop(conn, name) do
    DBus.call(
      conn,
      DevicePath.adapter_path(),
      @props_iface,
      "Get",
      "ss",
      [@adv_mgr_iface, name]
    )
  end

  # ── inbound method-call dispatch ──────────────────────────────────────────

  defp dispatch_method_call(%Bluez.Rebus.Message{header_fields: hf} = msg, state) do
    conn = state.conn

    case {hf[:interface], hf[:member]} do
      {@adv_iface, "Release"} ->
        # BlueZ dropped our advert (adapter reset, etc.). Ack, restore the adapter
        # props we changed on register (a later unregister no-ops once
        # registered? is false, so it can't restore Pairable for us), and mark
        # unregistered.
        Logger.info("Improv.Advert: BlueZ released the advertisement")
        set_adapter_prop(conn, "Pairable", {"b", true})
        Bluez.Rebus.reply(conn, msg)
        %{state | registered?: false}

      {@props_iface, "GetAll"} ->
        Bluez.Rebus.reply(conn, msg, [props(state)], "a{sv}")
        state

      {@props_iface, "Get"} ->
        reply_get(conn, msg, props(state))
        state

      {@props_iface, "Set"} ->
        Bluez.Rebus.reply_error(
          conn,
          msg,
          "org.freedesktop.DBus.Error.PropertyReadOnly",
          "read-only"
        )

        state

      {@introspect_iface, "Introspect"} ->
        Bluez.Rebus.reply(conn, msg, [introspect_xml(hf[:path])], "s")
        state

      {iface, member} ->
        Bluez.Rebus.reply_error(
          conn,
          msg,
          "org.freedesktop.DBus.Error.UnknownMethod",
          "#{iface}.#{member}"
        )

        state
    end
  rescue
    e ->
      Logger.warning(
        "Improv.Advert: inbound call handling raised " <>
          inspect(e, limit: 5, printable_limit: 200)
      )

      Bluez.Rebus.reply_error(
        state.conn,
        msg,
        "org.freedesktop.DBus.Error.Failed",
        "internal error"
      )

      state
  end

  defp reply_get(conn, msg, props) do
    case msg.body do
      [_iface, name | _] ->
        case List.keyfind(props, name, 0) do
          {^name, variant} ->
            Bluez.Rebus.reply(conn, msg, [variant], "v")

          _ ->
            Bluez.Rebus.reply_error(
              conn,
              msg,
              "org.freedesktop.DBus.Error.UnknownProperty",
              "#{name}"
            )
        end

      _ ->
        Bluez.Rebus.reply_error(
          conn,
          msg,
          "org.freedesktop.DBus.Error.InvalidArgs",
          "Get(interface, name)"
        )
    end
  end

  defp props(state), do: advertisement_props(state.local_name, state.capabilities)
end
