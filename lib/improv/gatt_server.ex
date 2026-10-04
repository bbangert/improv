defmodule Improv.GattServer do
  @moduledoc """
  Exports the Improv GATT application over D-Bus and serves the inbound method
  calls BlueZ makes against it.

  Same export+dispatch shape as `Bluez.Agent`/`Client`, scaled to
  a small object tree: an app-root `ObjectManager`, one `org.bluez.GattService1`,
  and five `org.bluez.GattCharacteristic1` objects (the Improv
  capabilities/current-state/error-state/rpc-command/rpc-result characteristics —
  all cleartext, **no encrypt flags**). Registration calls
  `GattManager1.RegisterApplication` on the adapter; BlueZ then reads the entire
  tree once via `GetManagedObjects` and afterwards calls
  `ReadValue`/`WriteValue`/`StartNotify`/`StopNotify` per characteristic.

  Notifications (current-state, error-state, rpc-result progress) are pushed by
  emitting `org.freedesktop.DBus.Properties.PropertiesChanged` on the
  characteristic's object path (`Bluez.Rebus.emit_signal/2`) — but
  only after a client has subscribed via `StartNotify`.

  Owns its own `rebus` connection (separate failure domain, like `Gatt`).
  Inbound rpc-command writes and notify subscriptions are forwarded to the
  Improv manager process (`:manager` option) which drives the state machine.

  The tree/props/read logic is pure (`managed_objects/2`, `props_for/3`,
  `read_value/2`, `introspect_xml/1`, `permission` helpers) and host-tested;
  the GenServer is a thin I/O shell over it.
  """

  use GenServer
  require Logger

  alias Bluez.{DBus, DevicePath}
  alias Improv.Protocol

  @om_iface "org.freedesktop.DBus.ObjectManager"
  @props_iface "org.freedesktop.DBus.Properties"
  @introspect_iface "org.freedesktop.DBus.Introspectable"
  @service_iface "org.bluez.GattService1"
  @char_iface "org.bluez.GattCharacteristic1"
  @char_methods ~w(ReadValue WriteValue StartNotify StopNotify)
  @gatt_mgr_iface "org.bluez.GattManager1"

  @app_root "/org/improv"
  @service_path @app_root <> "/service0"

  # bluetoothd may not have claimed org.bluez the instant we start (same window
  # Client/Agent retry through) — but unlike them we only register on demand
  # (when the manager arms), so registration just fails cleanly if not ready.
  @register_timeout_ms 10_000

  # Logical characteristic table — the single source of truth for the exported
  # tree, keyed by role. Paths nest under the service per the BlueZ contract.
  # Built at runtime from Protocol so the UUIDs have one home.
  @char_order [:current_state, :error_state, :rpc_command, :rpc_result, :capabilities]

  @char_flags %{
    current_state: ["read", "notify"],
    error_state: ["read", "notify"],
    rpc_command: ["write", "write-without-response"],
    rpc_result: ["read", "notify"],
    capabilities: ["read"]
  }

  @doc "Object path the Improv GATT application is rooted at."
  @spec app_root() :: String.t()
  def app_root, do: @app_root

  # Computed once at compile time — the table is fully static.
  @chars (
           uuids = Protocol.characteristic_uuids()

           @char_order
           |> Enum.with_index()
           |> Enum.map(fn {key, i} ->
             %{
               key: key,
               path: @service_path <> "/char#{i}",
               uuid: uuids[key],
               flags: @char_flags[key]
             }
           end)
         )

  @doc """
  The exported characteristics in tree order, each a map with `:key`, `:path`,
  `:uuid`, and `:flags`. Pure.
  """
  @spec chars() :: [%{key: atom(), path: String.t(), uuid: String.t(), flags: [String.t()]}]
  def chars, do: @chars

  @doc "Object path for a characteristic role, or `nil` if unknown."
  @spec char_path(atom()) :: String.t() | nil
  def char_path(key) do
    case Enum.find(chars(), &(&1.key == key)) do
      %{path: path} -> path
      nil -> nil
    end
  end

  # ── public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Register the GATT application with BlueZ (idempotent; runs off-loop)."
  @spec register(GenServer.server()) :: :ok
  def register(server \\ __MODULE__), do: GenServer.cast(server, :register)

  @doc "Unregister the GATT application (idempotent)."
  @spec unregister(GenServer.server()) :: :ok
  def unregister(server \\ __MODULE__), do: GenServer.cast(server, :unregister)

  @doc """
  Cache a new value for characteristic `key` and, if a client has subscribed,
  push it as a GATT notification. Used for current-state, error-state and
  rpc-result updates.
  """
  @spec notify(GenServer.server(), atom(), binary()) :: :ok
  def notify(server \\ __MODULE__, key, bytes) when is_atom(key) and is_binary(bytes) do
    GenServer.cast(server, {:notify, key, bytes})
  end

  # ── pure tree / props / read logic (host-tested) ──────────────────────────

  @doc """
  Build the `GetManagedObjects` reply tree (`a{oa{sa{sv}}}` payload) from the
  current `values` cache and `notifying` set. Pure.
  """
  @spec managed_objects(%{atom() => binary()}, MapSet.t()) :: list()
  def managed_objects(values, notifying) do
    [
      {@service_path, [{@service_iface, service_props()}]}
      | Enum.map(chars(), fn c ->
          {c.path, [{@char_iface, char_props(c, values, notifying)}]}
        end)
    ]
  end

  @doc """
  Properties for the object at `path`: `{interface, props_list}` or `:unknown`.
  Pure; used by `Properties.GetAll`/`Get` and the tree builder.
  """
  @spec props_for(String.t(), %{atom() => binary()}, MapSet.t()) ::
          {String.t(), list()} | :unknown
  def props_for(@service_path, _values, _notifying), do: {@service_iface, service_props()}

  def props_for(path, values, notifying) do
    case Enum.find(chars(), &(&1.path == path)) do
      nil -> :unknown
      c -> {@char_iface, char_props(c, values, notifying)}
    end
  end

  @doc """
  Read a characteristic value as a list of bytes (the `ay` body shape), or
  `{:error, bluez_error_name}` for a non-readable / unknown characteristic. Pure.
  """
  @spec read_value(String.t(), %{atom() => binary()}) ::
          {:ok, [byte()]} | {:error, String.t()}
  def read_value(path, values) do
    case Enum.find(chars(), &(&1.path == path)) do
      nil ->
        {:error, "org.bluez.Error.Failed"}

      c ->
        if "read" in c.flags do
          {:ok, :binary.bin_to_list(Map.get(values, c.key, <<>>))}
        else
          {:error, "org.bluez.Error.NotPermitted"}
        end
    end
  end

  @doc "Introspection XML for one exported object path. Pure."
  @spec introspect_xml(String.t()) :: String.t()
  def introspect_xml(path) do
    interfaces =
      cond do
        path == @app_root -> ~s(<interface name="#{@om_iface}"/>)
        path == @service_path -> ~s(<interface name="#{@service_iface}"/>)
        Enum.any?(chars(), &(&1.path == path)) -> ~s(<interface name="#{@char_iface}"/>)
        true -> ""
      end

    ~s(<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">\n<node>#{interfaces}</node>)
  end

  defp service_props do
    [{"UUID", {"s", Protocol.service_uuid()}}, {"Primary", {"b", true}}]
  end

  defp char_props(c, values, notifying) do
    base = [
      {"UUID", {"s", c.uuid}},
      {"Service", {"o", @service_path}},
      {"Flags", {"as", c.flags}}
    ]

    base
    |> maybe_value(c, values)
    |> maybe_notifying(c, notifying)
  end

  defp maybe_value(props, c, values) do
    bytes = Map.get(values, c.key)

    if is_binary(bytes) and "read" in c.flags do
      props ++ [{"Value", {"ay", :binary.bin_to_list(bytes)}}]
    else
      props
    end
  end

  defp maybe_notifying(props, c, notifying) do
    if "notify" in c.flags do
      props ++ [{"Notifying", {"b", MapSet.member?(notifying, c.key)}}]
    else
      props
    end
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
          manager: Keyword.get(opts, :manager, Improv),
          task_sup: Keyword.get(opts, :task_supervisor, Improv.TaskSupervisor),
          values: initial_values(Keyword.get(opts, :capabilities, Protocol.capabilities())),
          notifying: MapSet.new(),
          registered?: false
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:dbus_connect_failed, reason}}
    end
  end

  # Tests inject a stub connection via `:conn`; production connects to the system bus.
  defp get_conn(opts) do
    case Keyword.get(opts, :conn) do
      nil -> Bluez.Rebus.connect(:system)
      conn when is_pid(conn) -> {:ok, conn}
    end
  end

  defp initial_values(capabilities) do
    # Always advertise AUTHORIZED, no error — the manager updates
    # current-state/error via notify/3 as it progresses. The capabilities
    # byte is derived once by the supervisor (`:capabilities` opt) so it
    # matches the advertisement's ServiceData; the bare default is
    # scan-only (identify/device-info unconfigured).
    %{
      current_state: Protocol.encode_state(:authorized),
      error_state: Protocol.encode_error(:none),
      capabilities: capabilities
    }
  end

  @impl GenServer
  def handle_cast(:register, %{registered?: true} = state), do: {:noreply, state}

  def handle_cast(:register, state) do
    # RegisterApplication blocks until BlueZ has read our whole tree via the
    # GetManagedObjects call it makes back into THIS handler — so it must run
    # off the GenServer loop or it deadlocks. We mark registered? optimistically
    # so notifications flow immediately, and heal it back to false if the Task
    # reports failure so a later register/1 can retry.
    conn = state.conn
    parent = self()
    run_task(state, fn -> send(parent, {:register_result, do_register(conn)}) end)
    {:noreply, %{state | registered?: true}}
  end

  def handle_cast(:unregister, %{registered?: false} = state), do: {:noreply, state}

  def handle_cast(:unregister, state) do
    conn = state.conn
    run_task(state, fn -> do_unregister(conn) end)
    {:noreply, %{state | registered?: false}}
  end

  def handle_cast({:notify, key, bytes}, state) do
    state = put_in(state.values[key], bytes)

    if MapSet.member?(state.notifying, key) do
      emit_notification(state.conn, key, bytes)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:dbus_call, %Bluez.Rebus.Message{} = msg}, state) do
    {:noreply, dispatch_method_call(msg, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_ref: ref} = state) do
    {:stop, {:dbus_connection_down, reason}, state}
  end

  # Heal the optimistic registered? flag if RegisterApplication actually failed,
  # so a later register/1 retries instead of being skipped by the guard.
  def handle_info({:register_result, {:ok, _}}, state), do: {:noreply, state}

  def handle_info({:register_result, {:error, _reason}}, state) do
    {:noreply, %{state | registered?: false}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── registration (outbound, off-loop) ─────────────────────────────────────

  # Run an outbound D-Bus task off the GenServer loop. The bare-Task fallback
  # inside Improv.Tasks matters here: without it the {:register_result, _}
  # heal would never arrive and registered? would stick at true.
  defp run_task(%{task_sup: sup}, fun), do: Improv.Tasks.run(sup, fun, "Improv.GattServer")

  defp do_register(conn) do
    case DBus.call(
           conn,
           DevicePath.adapter_path(),
           @gatt_mgr_iface,
           "RegisterApplication",
           "oa{sv}",
           [@app_root, []],
           @register_timeout_ms
         ) do
      {:ok, _} = ok ->
        Logger.info("Improv.GattServer: registered GATT application at #{@app_root}")
        ok

      {:error, "org.bluez.Error.AlreadyExists"} ->
        Logger.debug("Improv.GattServer: GATT application already registered")
        {:ok, :already}

      {:error, reason} = err ->
        Logger.error("Improv.GattServer: RegisterApplication failed: #{inspect(reason)}")
        err
    end
  end

  defp do_unregister(conn) do
    case DBus.call(
           conn,
           DevicePath.adapter_path(),
           @gatt_mgr_iface,
           "UnregisterApplication",
           "o",
           [@app_root],
           @register_timeout_ms
         ) do
      {:ok, _} -> Logger.info("Improv.GattServer: unregistered GATT application")
      {:error, reason} -> Logger.debug("Improv.GattServer: unregister: #{inspect(reason)}")
    end
  end

  # ── inbound method-call dispatch ──────────────────────────────────────────

  defp dispatch_method_call(%Bluez.Rebus.Message{header_fields: hf} = msg, state) do
    conn = state.conn

    case {hf[:interface], hf[:member]} do
      {@om_iface, "GetManagedObjects"} ->
        reply(conn, msg, [managed_objects(state.values, state.notifying)], "a{oa{sa{sv}}}")
        state

      {@props_iface, "GetAll"} ->
        reply_get_all(conn, msg, hf, state)
        state

      {@props_iface, "Get"} ->
        reply_get(conn, msg, hf, state)
        state

      {@props_iface, "Set"} ->
        reply_error(conn, msg, "org.freedesktop.DBus.Error.PropertyReadOnly", "read-only")
        state

      {@char_iface, member} when member in @char_methods ->
        dispatch_char_call(member, msg, hf, state)

      {@introspect_iface, "Introspect"} ->
        reply(conn, msg, [introspect_xml(hf[:path])], "s")
        state

      {iface, member} ->
        reply_error(conn, msg, "org.freedesktop.DBus.Error.UnknownMethod", "#{iface}.#{member}")
        state
    end
  rescue
    e ->
      # Bound the log (attacker-influenced bytes) and reply a STATIC error string —
      # never echo exception text derived from peer input back over D-Bus.
      Logger.warning(
        "Improv.GattServer: inbound call handling raised " <>
          inspect(e, limit: 5, printable_limit: 200)
      )

      # Always answer a reply-expecting call so BlueZ doesn't block on its timeout.
      reply_error(state.conn, msg, "org.freedesktop.DBus.Error.Failed", "internal error")
      state
  end

  defp dispatch_char_call("ReadValue", msg, hf, state) do
    reply_read_value(state.conn, msg, hf, state)
    state
  end

  defp dispatch_char_call("WriteValue", msg, hf, state), do: handle_write_value(msg, hf, state)
  defp dispatch_char_call("StartNotify", msg, hf, state), do: handle_start_notify(msg, hf, state)
  defp dispatch_char_call("StopNotify", msg, hf, state), do: handle_stop_notify(msg, hf, state)

  defp reply_get_all(conn, msg, hf, state) do
    case props_for(hf[:path], state.values, state.notifying) do
      {_iface, props} -> reply(conn, msg, [props], "a{sv}")
      :unknown -> reply(conn, msg, [[]], "a{sv}")
    end
  end

  defp reply_get(conn, msg, hf, state) do
    case msg.body do
      [_iface, name | _] ->
        with {_iface, props} <- props_for(hf[:path], state.values, state.notifying),
             {^name, variant} <- List.keyfind(props, name, 0) do
          reply(conn, msg, [variant], "v")
        else
          _ -> reply_error(conn, msg, "org.freedesktop.DBus.Error.UnknownProperty", "#{name}")
        end

      _ ->
        reply_error(conn, msg, "org.freedesktop.DBus.Error.InvalidArgs", "Get(interface, name)")
    end
  end

  defp reply_read_value(conn, msg, hf, state) do
    case read_value(hf[:path], state.values) do
      {:ok, byte_list} -> reply(conn, msg, [byte_list], "ay")
      {:error, name} -> reply_error(conn, msg, name, "not readable")
    end
  end

  defp handle_write_value(msg, hf, state) do
    case Enum.find(chars(), &(&1.path == hf[:path])) do
      %{key: :rpc_command} = c ->
        bytes = to_binary(Enum.at(msg.body, 0))
        notify_manager(state, {:improv_rpc_command, bytes})
        notify_manager(state, {:improv_client_activity, c.key})
        reply(state.conn, msg)

      _ ->
        reply_error(state.conn, msg, "org.bluez.Error.NotPermitted", "not writable")
    end

    state
  end

  defp handle_start_notify(msg, hf, state) do
    case Enum.find(chars(), &(&1.path == hf[:path])) do
      %{key: key, flags: flags} when key != nil ->
        if "notify" in flags do
          notify_manager(state, {:improv_client_activity, key})
          reply(state.conn, msg)
          %{state | notifying: MapSet.put(state.notifying, key)}
        else
          reply_error(state.conn, msg, "org.bluez.Error.NotSupported", "no notify")
          state
        end

      _ ->
        reply_error(state.conn, msg, "org.bluez.Error.Failed", "unknown characteristic")
        state
    end
  end

  defp handle_stop_notify(msg, hf, state) do
    reply(state.conn, msg)

    case Enum.find(chars(), &(&1.path == hf[:path])) do
      %{key: key} -> %{state | notifying: MapSet.delete(state.notifying, key)}
      _ -> state
    end
  end

  defp emit_notification(conn, key, bytes) do
    Bluez.Rebus.emit_signal(conn,
      path: char_path(key),
      interface: @props_iface,
      member: "PropertiesChanged",
      signature: "sa{sv}as",
      body: [@char_iface, [{"Value", {"ay", :binary.bin_to_list(bytes)}}], []]
    )
  end

  defp notify_manager(%{manager: nil}, _msg), do: :ok

  defp notify_manager(%{manager: manager}, msg) do
    pid = if is_pid(manager), do: manager, else: Process.whereis(manager)

    if is_pid(pid) and Process.alive?(pid) do
      send(pid, msg)
    else
      # A dropped rpc-command would otherwise be invisible — the BLE client still
      # got a success reply. Surface it (manager not started yet / crashed).
      Logger.debug("Improv.GattServer: dropping #{inspect(elem(msg, 0))}; manager unavailable")
    end

    :ok
  end

  # BlueZ encodes `ay` as a list of byte integers (rebus decode); accept a raw
  # binary too for safety.
  defp to_binary(bytes) when is_list(bytes), do: :erlang.list_to_binary(bytes)
  defp to_binary(bytes) when is_binary(bytes), do: bytes
  defp to_binary(_), do: <<>>

  # Thin wrappers so the dispatch reads cleanly and tests can stub the conn.
  defp reply(conn, msg), do: Bluez.Rebus.reply(conn, msg)
  defp reply(conn, msg, body, sig), do: Bluez.Rebus.reply(conn, msg, body, sig)
  defp reply_error(conn, msg, name, text), do: Bluez.Rebus.reply_error(conn, msg, name, text)
end
