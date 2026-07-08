defmodule Improv do
  @moduledoc """
  Improv-over-BLE Wi-Fi provisioning manager — the GenServer that ties the
  protocol codec, GATT server and advertisement into a working subsystem.

  Always started on BT targets but **disarmed** by default. It arms (exports the
  GATT app + advertisement, starts a session timer) only when the device boots
  with no network connectivity, and tears itself back down on a 5-minute idle
  timeout or once provisioning completes.

  ## State machine

      :disarmed → :advertising → :connected → :provisioning → :provisioned

  A failed/timed-out connect reverts `:provisioning → :connected` and surfaces the
  reason via `state.error` (an error byte to the client) — there is no distinct
  `:error` FSM state.

  We always advertise current-state AUTHORIZED until a submit moves us to
  PROVISIONING; security comes from the no-connectivity arm gate + the session
  timeout, not from the Improv authorization handshake.

  ## Arm policy

  Arm **only** on a no-connectivity boot, and **only once per boot** — we do NOT
  re-arm if connectivity drops later (re-arm requires a reboot). After a session
  ends (timeout or provisioned) we disarm and stay disarmed.

  ## Timeout reset rule

  The 5-minute idle timer resets only on a *meaningful* state advance (first
  client connect, a valid submit) — never on arbitrary client activity, so a
  flooding peer cannot hold the session open forever. An absolute session cap
  (default 15 minutes) bounds the whole session regardless of activity.

  State changes broadcast `{:improv_status, status}` on the `"bluetooth:improv"`
  PubSub topic (`status_topic/0`) when a `pubsub:` is configured, for host UIs.

  Wi-Fi scan/apply goes through the `:wifi` dep (`Improv.Wifi` by default);
  this module routes RPCs to it and pushes the resulting GATT notifications.
  """

  use GenServer
  require Logger

  alias Improv.{Advert, GattServer, Protocol}

  @topic "bluetooth:improv"

  @session_timeout_ms 5 * 60 * 1000
  # Absolute cap on a session regardless of activity, so repeated valid submits
  # can't extend the idle window indefinitely (a connected peer resets the idle
  # timer on every valid submit). Hard disarm at this deadline.
  @session_cap_ms 15 * 60 * 1000
  # Brief hold after PROVISIONED so the client can read the result before teardown.
  @provisioned_hold_ms 10_000
  # Bound on how long we wait for the Wi-Fi interface to join after a submit
  # before declaring the credentials bad and reverting to AUTHORIZED for a retry.
  @connect_timeout_ms 30_000
  # Grace period before arming on a seemingly-offline boot: the boot connectivity
  # read races interface bring-up (DHCP/link), so an Ethernet device looks offline
  # for the first few seconds. Re-check after this delay and arm only if STILL
  # offline — otherwise every Ethernet boot would spuriously advertise + suspend
  # the proxy scan (HW-found on rpi3).
  @boot_grace_ms 20_000

  @connection_topic ["interface", :_, "connection"]

  @type fsm :: :disarmed | :advertising | :connected | :provisioning | :provisioned

  # ── public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "PubSub topic carrying `{:improv_status, status}` messages."
  @spec status_topic() :: String.t()
  def status_topic, do: @topic

  @doc """
  Current provisioning status: `%{state: fsm, error: atom | nil}`. Returns the
  disarmed shape when the manager isn't running (off-target / subtree down).
  """
  @spec status(GenServer.server()) :: %{state: fsm(), error: atom() | nil}
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> %{state: :disarmed, error: nil}
  end

  # ── pure helpers (host-tested) ─────────────────────────────────────────────

  @doc "Map an FSM state to the current-state atom we advertise/notify. Pure."
  @spec current_state_atom(fsm()) :: atom()
  def current_state_atom(:provisioning), do: :provisioning
  def current_state_atom(:provisioned), do: :provisioned
  # advertising / connected / disarmed all present as AUTHORIZED.
  def current_state_atom(_), do: :authorized

  @doc "Improv SSID length rule: 1..32 bytes. Pure."
  @spec valid_ssid?(binary()) :: boolean()
  def valid_ssid?(ssid) when is_binary(ssid), do: byte_size(ssid) in 1..32
  def valid_ssid?(_), do: false

  @doc """
  Map a decoded command (or decode error) to the manager action. Pure — the
  GenServer executes the returned action. Returns:

    * `{:submit, ssid, pwd}` for a valid submit,
    * `:scan` for request-networks,
    * `{:reject, error_atom}` for an invalid submit / decode failure.
  """
  @spec command_action(Protocol.command() | Protocol.decode_error()) ::
          {:submit, binary(), binary()} | :scan | :identify | :device_info | {:reject, atom()}
  def command_action({:submit_wifi, ssid, pwd}) do
    if valid_ssid?(ssid), do: {:submit, ssid, pwd}, else: {:reject, :invalid_rpc}
  end

  def command_action({:request_wifi_networks}), do: :scan
  def command_action({:identify}), do: :identify
  def command_action({:device_info}), do: :device_info
  def command_action({:error, :unknown_command}), do: {:reject, :unknown_command}
  def command_action({:error, _}), do: {:reject, :invalid_rpc}

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    state = %{
      gatt: Keyword.get(opts, :gatt, GattServer),
      advert: Keyword.get(opts, :advert, Advert),
      wifi: Keyword.get(opts, :wifi, Improv.Wifi),
      # Wi-Fi interface being provisioned; threaded into every :wifi call and
      # matched against VintageNet connectivity events.
      ifname: Keyword.get(opts, :ifname, "wlan0"),
      # Connectivity probe for the arm gate (0-arity fun returning
      # :disconnected when offline); nil (the default) reads as online, so
      # Improv NEVER arms unless the host explicitly opts into offline-driven
      # arming by wiring a real probe. Fail-closed: an unconfigured host must
      # not expose the provisioning surface.
      network_type: Keyword.get(opts, :network_type),
      # Phoenix.PubSub for {:improv_status, _} broadcasts; nil = no-op.
      pubsub: Keyword.get(opts, :pubsub),
      # Identify (0x02) callback — something physically observable (blink an
      # LED, …), run fire-and-forget off the loop. nil (default) = the command
      # is unsupported and its capability bit stays off.
      identify_fun: Keyword.get(opts, :identify_fun),
      # Device Info (0x03) static strings, normalized to wire order at init.
      # nil (default) = unsupported, capability bit off.
      device_info: device_info_strings(Keyword.get(opts, :device_info)),
      scanner: Keyword.get(opts, :scanner, Bluez.Client),
      task_sup: Keyword.get(opts, :task_supervisor, Improv.TaskSupervisor),
      timeout_ms: Keyword.get(opts, :timeout_ms, @session_timeout_ms),
      session_cap_ms: Keyword.get(opts, :session_cap_ms, @session_cap_ms),
      connect_timeout_ms: Keyword.get(opts, :connect_timeout_ms, @connect_timeout_ms),
      boot_grace_ms: Keyword.get(opts, :boot_grace_ms, @boot_grace_ms),
      provisioned_hold_ms: Keyword.get(opts, :provisioned_hold_ms, @provisioned_hold_ms),
      subscribe?: Keyword.get(opts, :subscribe?, true),
      fsm: :disarmed,
      error: nil,
      # One-shot arm gate: arm at most once per boot, only when offline.
      arm_allowed?: true,
      timer: nil,
      provision_timer: nil,
      cap_timer: nil
    }

    {:ok, state, {:continue, :evaluate_boot}}
  end

  @impl GenServer
  def handle_continue(:evaluate_boot, state) do
    maybe_subscribe_connectivity(state)

    if online?(state) do
      Logger.debug("Improv: connectivity present at boot — staying disarmed")
      {:noreply, state}
    else
      # Likely just DHCP/link not finished — re-check after a grace period rather
      # than arming immediately (avoids spurious arming on Ethernet boots).
      Logger.debug("Improv: offline at boot — re-checking after #{state.boot_grace_ms}ms")
      Process.send_after(self(), :evaluate_arm, state.boot_grace_ms)
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, %{state: state.fsm, error: state.error}, state}
  end

  @impl GenServer
  # Boot-grace re-check: arm only if STILL offline (else it was just DHCP lag).
  def handle_info(:evaluate_arm, state) do
    if online?(state) do
      Logger.info("Improv: connectivity came up during boot grace — staying disarmed")
      {:noreply, state}
    else
      Logger.info("Improv: still no connectivity after boot grace — arming provisioning")
      {:noreply, arm(state)}
    end
  end

  def handle_info({:improv_rpc_command, bytes}, state) do
    {:noreply, dispatch_command(bytes, state)}
  end

  # First genuine client connect advances :advertising → :connected and resets
  # the timer. Later activity does NOT reset it (timeout reset rule).
  def handle_info({:improv_client_activity, _key}, %{fsm: :advertising} = state) do
    {:noreply, transition(state, :connected)}
  end

  def handle_info({:improv_client_activity, _key}, state), do: {:noreply, state}

  # Provisioned only when the provisioning interface reaches full :internet
  # connectivity. NOT :lan (a wrong password flaps associate→handshake-fail→drop,
  # blipping :lan transiently — that would falsely report success), and NOT
  # other ifaces (their connectivity says nothing about the submitted Wi-Fi).
  # If it never reaches :internet, the connect timer fires → unable_to_connect.
  def handle_info(
        {VintageNet, ["interface", ifname, "connection"], _old, :internet, _meta},
        %{fsm: :provisioning, ifname: ifname} = state
      ) do
    {:noreply, mark_provisioned(state)}
  end

  def handle_info({VintageNet, ["interface", _iface, "connection"], _old, _new, _meta}, state) do
    {:noreply, state}
  end

  # Join in flight — the connect timer bounds it; don't cut it on idle timeout.
  def handle_info(:session_timeout, %{fsm: :provisioning} = state), do: {:noreply, state}

  # Already provisioned — the teardown timer is scheduled; don't double-disarm.
  def handle_info(:session_timeout, %{fsm: :provisioned} = state), do: {:noreply, state}

  def handle_info(:session_timeout, state) do
    Logger.info("Improv: session idle timeout — disarming")
    {:noreply, disarm(state)}
  end

  # Absolute session cap — disarm regardless of activity (defeats indefinite
  # idle-timer extension via repeated valid submits).
  def handle_info(:session_cap, %{fsm: :disarmed} = state), do: {:noreply, state}

  def handle_info(:session_cap, state) do
    Logger.info("Improv: absolute session cap reached — disarming")
    {:noreply, disarm(state)}
  end

  def handle_info(:provisioned_teardown, state) do
    {:noreply, disarm(state)}
  end

  # wlan0 didn't join in time — bad credentials / out of range. Report the error
  # and revert to AUTHORIZED so the provisioner can retry within the session.
  def handle_info(:provisioning_failed, %{fsm: :provisioning} = state) do
    state = push_error(state, :unable_to_connect)
    {:noreply, state |> Map.put(:provision_timer, nil) |> transition(:connected)}
  end

  def handle_info(:provisioning_failed, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  # ── command dispatch ───────────────────────────────────────────────────────

  defp dispatch_command(bytes, state) do
    case command_action(Protocol.decode_command(bytes)) do
      {:submit, ssid, pwd} -> submit_wifi(ssid, pwd, state)
      :scan -> request_networks(state)
      :identify -> run_identify(state)
      :device_info -> send_device_info(state)
      {:reject, error} -> push_error(state, error)
    end
  end

  # Identify: fire-and-forget via the Task.Supervisor, NO RPC result (per
  # spec). Unconfigured hosts advertise the capability bit off, so a compliant
  # client never sends it — reject like an unknown command if one does anyway.
  defp run_identify(%{identify_fun: nil} = state), do: push_error(state, :unknown_command)

  defp run_identify(%{identify_fun: fun} = state) do
    run_task(state, fun)
    state
  end

  defp send_device_info(%{device_info: nil} = state), do: push_error(state, :unknown_command)

  defp send_device_info(state) do
    notify_result(
      state,
      Protocol.encode_rpc_result(Protocol.device_info_command(), state.device_info)
    )

    state
  end

  # Wire order per the Improv spec: firmware name, firmware version, hardware
  # variant, device name.
  defp device_info_strings(nil), do: nil

  defp device_info_strings(info) do
    [
      Keyword.fetch!(info, :firmware_name),
      Keyword.fetch!(info, :firmware_version),
      Keyword.fetch!(info, :hardware),
      Keyword.fetch!(info, :device_name)
    ]
  end

  defp submit_wifi(ssid, pwd, state) do
    state = %{state | error: nil} |> transition(:provisioning) |> arm_provision_timer()
    # Improv.Wifi applies the credentials; PROVISIONED is detected via the
    # interface connectivity event above. configure/3 returns quickly (best-effort).
    safe_apply(state.wifi, :configure, [ssid, pwd, wifi_opts(state)])
    state
  end

  defp arm_provision_timer(state) do
    state = cancel_provision_timer(state)

    %{
      state
      | provision_timer:
          Process.send_after(self(), :provisioning_failed, state.connect_timeout_ms)
    }
  end

  defp cancel_provision_timer(%{provision_timer: nil} = state), do: state

  defp cancel_provision_timer(%{provision_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | provision_timer: nil}
  end

  defp request_networks(state) do
    %{gatt: gatt, wifi: wifi} = state
    wifi_opts = wifi_opts(state)

    # quick_scan sleeps ~2s — run off the GenServer loop, under the Improv
    # Task.Supervisor (crash visibility). The Task pushes the per-network results
    # then the empty terminator so the client's list completes.
    run_task(state, fn ->
      networks =
        case safe_apply(wifi, :scan_networks, [wifi_opts]) do
          {:ok, ns} when is_list(ns) -> ns
          _ -> []
        end

      Enum.each(networks, fn n ->
        GattServer.notify(
          gatt,
          :rpc_result,
          Protocol.encode_wifi_network_entry(n.ssid, n.rssi, n.secured)
        )
      end)

      GattServer.notify(
        gatt,
        :rpc_result,
        Protocol.encode_rpc_result(Protocol.request_networks_command(), [])
      )
    end)

    state
  end

  # ── arm / disarm / transitions ─────────────────────────────────────────────

  defp arm(%{fsm: :disarmed, arm_allowed?: true} = state) do
    # We only arm on a no-connectivity boot — there's no HA client to consume the
    # proxy scan, so suspend it for the session (also frees the radio for the BLE
    # peripheral connection). Resumed on disarm.
    suspend_proxy_scan(state)
    GattServer.register(state.gatt)
    Advert.register(state.advert)
    Advert.set_state(state.advert, :authorized)
    notify_state(state, :authorized)

    %{state | fsm: :advertising, arm_allowed?: false, error: nil}
    |> reset_timer()
    |> start_cap_timer()
    |> broadcast()
  end

  defp arm(state), do: state

  defp disarm(state) do
    Advert.unregister(state.advert)
    GattServer.unregister(state.gatt)
    resume_proxy_scan(state)

    %{state | fsm: :disarmed}
    |> cancel_timer()
    |> cancel_provision_timer()
    |> cancel_cap_timer()
    |> broadcast()
  end

  # Advance the FSM, push the current-state notification + advert update, reset
  # the idle timer (only state advances call this), and broadcast.
  defp transition(state, new_fsm) do
    cs = current_state_atom(new_fsm)
    notify_state(state, cs)
    Advert.set_state(state.advert, cs)

    %{state | fsm: new_fsm}
    |> reset_timer()
    |> broadcast()
  end

  defp mark_provisioned(state) do
    state = state |> cancel_provision_timer() |> transition(:provisioned)
    push_redirect_result(state)
    # Hold briefly so the client reads the result, then tear down.
    Process.send_after(self(), :provisioned_teardown, state.provisioned_hold_ms)
    state
  end

  # On success the Improv RPC-result carries the device's web-UI URL on the new
  # network, so the provisioner can redirect there. Skipped if no IPv4 yet.
  defp push_redirect_result(state) do
    case safe_apply(state.wifi, :redirect_url, [wifi_opts(state)]) do
      url when is_binary(url) ->
        notify_result(state, Protocol.encode_rpc_result(Protocol.submit_wifi_command(), [url]))

      _ ->
        :ok
    end
  end

  defp push_error(state, error) do
    notify(state, :error_state, Protocol.encode_error(error))
    %{state | error: error} |> broadcast()
  end

  # ── notifications / effects ────────────────────────────────────────────────

  defp notify_state(state, cs_atom),
    do: notify(state, :current_state, Protocol.encode_state(cs_atom))

  defp notify_result(state, bytes), do: notify(state, :rpc_result, bytes)
  defp notify(state, key, bytes), do: GattServer.notify(state.gatt, key, bytes)

  # Opts threaded into every :wifi call (each takes a trailing keyword list).
  defp wifi_opts(state), do: [ifname: state.ifname]

  # Call the Wi-Fi module through a variable, rescued so a raising impl can't
  # crash the manager (or the scan Task). Used from both the loop and the Task.
  defp safe_apply(mod, fun, args) do
    apply(mod, fun, args)
  rescue
    e ->
      Logger.warning("Improv: wifi #{fun} failed: #{inspect(e, limit: 5)}")
      {:error, :wifi_unavailable}
  end

  defp broadcast(%{pubsub: nil} = state), do: state

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      @topic,
      {:improv_status, %{state: state.fsm, error: state.error}}
    )

    state
  end

  # ── timer ──────────────────────────────────────────────────────────────────

  defp reset_timer(state) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :session_timeout, state.timeout_ms)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  # Absolute cap, armed once at arm and never reset, so it bounds the whole
  # session no matter how often the idle timer is refreshed.
  defp start_cap_timer(state) do
    state = cancel_cap_timer(state)
    %{state | cap_timer: Process.send_after(self(), :session_cap, state.session_cap_ms)}
  end

  defp cancel_cap_timer(%{cap_timer: nil} = state), do: state

  defp cancel_cap_timer(%{cap_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | cap_timer: nil}
  end

  # ── tasks ──────────────────────────────────────────────────────────────────

  # Run off the GenServer loop, under the Improv Task.Supervisor when it's alive
  # (production), else a bare Task (host tests). Falls back to Task.start if the
  # supervisor refuses (e.g. max_restarts) so work is never silently dropped —
  # but that production case is logged: a restart-throttled supervisor spawning
  # unsupervised work is exactly when crash visibility matters most. No log when
  # the supervisor simply isn't registered (host tests).
  defp run_task(%{task_sup: sup}, fun) do
    case Process.whereis(sup) do
      nil ->
        Task.start(fun)
        :ok

      _pid ->
        case Task.Supervisor.start_child(sup, fun) do
          {:ok, _} ->
            :ok

          error ->
            Logger.warning(
              "Improv Task.Supervisor #{inspect(sup)} refused (#{inspect(error)}); " <>
                "running unsupervised"
            )

            Task.start(fun)
            :ok
        end
    end
  end

  # ── connectivity ─────────────────────────────────────────────────────────

  # No probe configured → treated as online → never arms (see init/1).
  defp online?(%{network_type: nil}), do: true
  defp online?(state), do: state.network_type.() != :disconnected

  # Best-effort: only cast when the scanner is actually running (no-op off-target
  # / in host tests). suspend_scan/resume_scan are themselves casts.
  defp suspend_proxy_scan(state), do: scanner_cast(state.scanner, :suspend_scan)
  defp resume_proxy_scan(state), do: scanner_cast(state.scanner, :resume_scan)

  # `GenServer.cast` to an unregistered name already returns `:ok`, so no
  # whereis-guard is needed (it was a TOCTOU no-op anyway).
  defp scanner_cast(scanner, msg), do: GenServer.cast(scanner, msg)

  defp maybe_subscribe_connectivity(%{subscribe?: false}), do: :ok

  defp maybe_subscribe_connectivity(_state) do
    if Code.ensure_loaded?(VintageNet) do
      _ = Application.ensure_all_started(:vintage_net)
      apply(VintageNet, :subscribe, [@connection_topic])
    end

    :ok
  end
end
