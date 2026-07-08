defmodule ImprovTest do
  # async: false — these tests subscribe to and broadcast on the global
  # "bluetooth:improv" PubSub topic (every manager transition broadcasts), so
  # concurrent modules would risk cross-test {:improv_status, _} interference.
  use ExUnit.Case, async: false

  alias Improv
  alias Improv.Protocol

  # Records every cast it receives and forwards it to the test pid tagged, so we
  # can assert the manager's effects on GattServer / Advert.
  defmodule Recorder do
    use GenServer
    def start_link({test, tag}), do: GenServer.start_link(__MODULE__, {test, tag})
    @impl true
    def init(s), do: {:ok, s}
    @impl true
    def handle_cast(msg, {test, tag} = s) do
      send(test, {tag, msg})
      {:noreply, s}
    end
  end

  defmodule StubWifi do
    def scan_networks(_opts \\ []) do
      {:ok,
       [
         %{ssid: "Net1", rssi: -50, secured: true},
         %{ssid: "Net2", rssi: -70, secured: false}
       ]}
    end

    def configure(_ssid, _pwd, _opts \\ []), do: :ok
    def redirect_url(_opts \\ []), do: "http://192.168.1.50/"
  end

  # Like StubWifi but with no bound IPv4 yet (redirect_url → nil).
  defmodule StubWifiNoIp do
    def scan_networks(_opts \\ []), do: {:ok, []}
    def configure(_ssid, _pwd, _opts \\ []), do: :ok
    def redirect_url(_opts \\ []), do: nil
  end

  # Echoes each call's opts to the process registered as :improv_echo_test, so
  # tests can assert the manager threads ifname: into every wifi call.
  defmodule EchoWifi do
    def scan_networks(opts \\ []) do
      send(:improv_echo_test, {:scan_opts, opts})
      {:ok, []}
    end

    def configure(_ssid, _pwd, opts \\ []) do
      send(:improv_echo_test, {:configure_opts, opts})
      :ok
    end

    def redirect_url(opts \\ []) do
      send(:improv_echo_test, {:redirect_opts, opts})
      "http://192.168.1.50/"
    end
  end

  defp start_manager(opts) do
    {:ok, gatt} = Recorder.start_link({self(), :gatt})
    {:ok, advert} = Recorder.start_link({self(), :advert})
    {:ok, scanner} = Recorder.start_link({self(), :scanner})

    base = [
      name: nil,
      gatt: gatt,
      advert: advert,
      scanner: scanner,
      wifi: StubWifi,
      # The pubsub default is nil (no-op) since the extraction seams landed;
      # these tests assert the status broadcasts, so wire the real one.
      pubsub: Improv.TestPubSub,
      subscribe?: false,
      # No boot grace by default so arm-on-offline tests fire immediately.
      boot_grace_ms: 0,
      timeout_ms: 10_000
    ]

    {:ok, mgr} = Improv.start_link(Keyword.merge(base, opts))
    %{mgr: mgr, gatt: gatt, advert: advert}
  end

  defp offline, do: fn -> :disconnected end
  defp online, do: fn -> :ethernet end

  defp submit_frame(ssid, pwd) do
    data = <<byte_size(ssid), ssid::binary, byte_size(pwd), pwd::binary>>
    body = <<0x01, byte_size(data), data::binary>>
    <<body::binary, Protocol.checksum(body)>>
  end

  describe "pure helpers" do
    test "current_state_atom mapping" do
      assert Improv.current_state_atom(:advertising) == :authorized
      assert Improv.current_state_atom(:connected) == :authorized
      assert Improv.current_state_atom(:error) == :authorized
      assert Improv.current_state_atom(:provisioning) == :provisioning
      assert Improv.current_state_atom(:provisioned) == :provisioned
    end

    test "valid_ssid? enforces 1..32 bytes" do
      refute Improv.valid_ssid?("")
      assert Improv.valid_ssid?("a")
      assert Improv.valid_ssid?(String.duplicate("a", 32))
      refute Improv.valid_ssid?(String.duplicate("a", 33))
    end

    test "command_action routes decoded commands" do
      assert Improv.command_action({:submit_wifi, "Net", "pw"}) == {:submit, "Net", "pw"}
      assert Improv.command_action({:submit_wifi, "", "pw"}) == {:reject, :invalid_rpc}
      assert Improv.command_action({:request_wifi_networks}) == :scan
      assert Improv.command_action({:error, :unknown_command}) == {:reject, :unknown_command}
      assert Improv.command_action({:error, :bad_checksum}) == {:reject, :invalid_rpc}
    end
  end

  describe "arm policy" do
    test "never arms when no network_type probe is configured (fail-closed)" do
      # nil probe reads as online: an unconfigured host must not expose the
      # provisioning surface just because it forgot to wire connectivity.
      %{mgr: mgr} = start_manager([])

      refute_receive {:gatt, :register}, 150
      assert %{state: :disarmed} = Improv.status(mgr)
    end

    test "arms on a no-connectivity boot" do
      Phoenix.PubSub.subscribe(Improv.TestPubSub, Improv.status_topic())
      %{mgr: mgr} = start_manager(network_type: offline())

      assert_receive {:gatt, :register}
      assert_receive {:advert, :register}
      assert_receive {:advert, {:set_state, :authorized}}
      assert_receive {:gatt, {:notify, :current_state, <<0x02>>}}
      assert_receive {:improv_status, %{state: :advertising}}

      assert %{state: :advertising} = Improv.status(mgr)
    end

    test "stays disarmed when connectivity is present at boot" do
      %{mgr: mgr} = start_manager(network_type: online())

      refute_receive {:gatt, :register}, 100
      assert %{state: :disarmed} = Improv.status(mgr)
    end

    test "does NOT arm if connectivity appears during the boot grace (DHCP race)" do
      # Offline at the boot instant, online by the time the grace re-check fires.
      {:ok, agent} = Agent.start_link(fn -> :disconnected end)
      nt = fn -> Agent.get(agent, & &1) end

      %{mgr: mgr} = start_manager(network_type: nt, boot_grace_ms: 80)
      Agent.update(agent, fn _ -> :ethernet end)

      refute_receive {:gatt, :register}, 300
      assert %{state: :disarmed} = Improv.status(mgr)
    end
  end

  describe "session timeout" do
    test "disarms after the idle timeout with no provisioning" do
      %{mgr: mgr} = start_manager(network_type: offline(), timeout_ms: 100)

      assert_receive {:gatt, :register}
      # Timer fires → disarm.
      assert_receive {:advert, :unregister}, 1000
      assert_receive {:gatt, :unregister}, 1000
      assert %{state: :disarmed} = Improv.status(mgr)
    end

    test "the absolute cap disarms regardless of activity" do
      %{mgr: mgr} =
        start_manager(network_type: offline(), timeout_ms: 100_000, session_cap_ms: 100)

      assert_receive {:gatt, :register}
      # Idle timer is long; the cap still tears the session down.
      assert_receive {:gatt, :unregister}, 1000
      assert %{state: :disarmed} = Improv.status(mgr)
    end

    test "arm suspends the proxy scan; disarm resumes it" do
      %{mgr: mgr} = start_manager(network_type: offline(), timeout_ms: 100)

      assert_receive {:scanner, :suspend_scan}
      assert_receive {:scanner, :resume_scan}, 1000
      assert %{state: :disarmed} = Improv.status(mgr)
    end

    test "a later disconnect does NOT re-arm after disarm (once per boot)" do
      %{mgr: mgr} = start_manager(network_type: offline(), timeout_ms: 100)

      assert_receive {:gatt, :register}
      assert_receive {:gatt, :unregister}, 1000
      assert %{state: :disarmed} = Improv.status(mgr)

      # A connectivity-change event must not re-arm.
      send(mgr, {VintageNet, ["interface", "eth0", "connection"], :internet, :disconnected, %{}})
      refute_receive {:gatt, :register}, 150
      assert %{state: :disarmed} = Improv.status(mgr)
    end
  end

  describe "client connect" do
    test "first activity advances advertising → connected" do
      %{mgr: mgr} = start_manager(network_type: offline())
      assert_receive {:gatt, :register}

      send(mgr, {:improv_client_activity, :rpc_command})
      assert %{state: :connected} = Improv.status(mgr)
    end

    test "activity while connected is a no-op (anti-flood: no extra effects)" do
      %{mgr: mgr} = start_manager(network_type: offline())
      assert_receive {:gatt, :register}
      assert_receive {:advert, {:set_state, :authorized}}

      # First activity: advertising → connected (transition re-sets AUTHORIZED).
      send(mgr, {:improv_client_activity, :rpc_command})
      assert_receive {:advert, {:set_state, :authorized}}
      assert %{state: :connected} = Improv.status(mgr)

      # Further activity while connected changes nothing and pushes no effects.
      send(mgr, {:improv_client_activity, :rpc_command})
      refute_receive {:advert, {:set_state, _}}, 100
      assert %{state: :connected} = Improv.status(mgr)
    end
  end

  describe "RPC dispatch" do
    test "submit-wifi moves to provisioning and notifies PROVISIONING" do
      %{mgr: mgr} = start_manager(network_type: offline())
      assert_receive {:gatt, :register}

      send(mgr, {:improv_rpc_command, submit_frame("MyNet", "secret12")})

      assert_receive {:gatt, {:notify, :current_state, <<0x03>>}}
      assert_receive {:advert, {:set_state, :provisioning}}
      assert %{state: :provisioning} = Improv.status(mgr)
    end

    test "a joined network during provisioning completes → PROVISIONED" do
      %{mgr: mgr} = start_manager(network_type: offline())
      assert_receive {:gatt, :register}

      send(mgr, {:improv_rpc_command, submit_frame("MyNet", "pw")})
      assert_receive {:gatt, {:notify, :current_state, <<0x03>>}}

      send(mgr, {VintageNet, ["interface", "wlan0", "connection"], :configuring, :internet, %{}})
      assert_receive {:gatt, {:notify, :current_state, <<0x04>>}}
      # Redirect URL pushed as a submit-wifi (0x01) RPC result.
      assert_receive {:gatt, {:notify, :rpc_result, result}}
      assert result == Protocol.encode_rpc_result(0x01, ["http://192.168.1.50/"])
      assert %{state: :provisioned} = Improv.status(mgr)
    end

    test "eth0 reaching :internet during provisioning does NOT mark provisioned" do
      %{mgr: mgr} = start_manager(network_type: offline(), connect_timeout_ms: 10_000)
      assert_receive {:gatt, :register}

      send(mgr, {:improv_rpc_command, submit_frame("MyNet", "pw")})
      assert_receive {:gatt, {:notify, :current_state, <<0x03>>}}

      # A non-wlan0 interface coming up must not be treated as Wi-Fi success.
      send(mgr, {VintageNet, ["interface", "eth0", "connection"], :lan, :internet, %{}})
      refute_receive {:gatt, {:notify, :current_state, <<0x04>>}}, 150
      assert %{state: :provisioning} = Improv.status(mgr)
    end

    test "identify runs the identify_fun off-loop with no RPC result" do
      test = self()

      %{mgr: mgr} =
        start_manager(
          network_type: offline(),
          identify_fun: fn -> send(test, :identified) end
        )

      assert_receive {:gatt, :register}

      frame = <<0x02, 0x00, Protocol.checksum(<<0x02, 0x00>>)>>
      send(mgr, {:improv_rpc_command, frame})

      assert_receive :identified
      # No RPC result and no error (per spec identify has no reply).
      refute_receive {:gatt, {:notify, :rpc_result, _}}, 100
      refute_receive {:gatt, {:notify, :error_state, _}}, 10
      assert %{state: :advertising, error: nil} = Improv.status(mgr)
    end

    test "identify without an identify_fun rejects as unknown command" do
      %{mgr: mgr} = start_manager(network_type: offline())
      assert_receive {:gatt, :register}

      frame = <<0x02, 0x00, Protocol.checksum(<<0x02, 0x00>>)>>
      send(mgr, {:improv_rpc_command, frame})

      assert_receive {:gatt, {:notify, :error_state, <<0x02>>}}
    end

    test "device-info notifies one RPC result with the four configured strings" do
      %{mgr: mgr} =
        start_manager(
          network_type: offline(),
          device_info: [
            firmware_name: "Universal Proxy",
            firmware_version: "1.2.3",
            hardware: "Raspberry Pi 3 Model B Plus",
            device_name: "Universal Proxy 507f"
          ]
        )

      assert_receive {:gatt, :register}

      frame = <<0x03, 0x00, Protocol.checksum(<<0x03, 0x00>>)>>
      send(mgr, {:improv_rpc_command, frame})

      expected =
        Protocol.encode_rpc_result(0x03, [
          "Universal Proxy",
          "1.2.3",
          "Raspberry Pi 3 Model B Plus",
          "Universal Proxy 507f"
        ])

      assert_receive {:gatt, {:notify, :rpc_result, ^expected}}
    end

    test "device-info without configured strings rejects as unknown command" do
      %{mgr: mgr} = start_manager(network_type: offline())
      assert_receive {:gatt, :register}

      frame = <<0x03, 0x00, Protocol.checksum(<<0x03, 0x00>>)>>
      send(mgr, {:improv_rpc_command, frame})

      assert_receive {:gatt, {:notify, :error_state, <<0x02>>}}
    end

    test "a custom ifname: drives the connectivity match and every wifi call" do
      Process.register(self(), :improv_echo_test)
      %{mgr: mgr} = start_manager(network_type: offline(), wifi: EchoWifi, ifname: "wlan1")
      assert_receive {:gatt, :register}

      send(mgr, {:improv_rpc_command, submit_frame("MyNet", "pw")})
      assert_receive {:configure_opts, [ifname: "wlan1"]}
      assert_receive {:gatt, {:notify, :current_state, <<0x03>>}}

      # The default interface joining is NOT the one being provisioned.
      send(mgr, {VintageNet, ["interface", "wlan0", "connection"], :configuring, :internet, %{}})
      refute_receive {:gatt, {:notify, :current_state, <<0x04>>}}, 150

      # The configured interface joining completes provisioning.
      send(mgr, {VintageNet, ["interface", "wlan1", "connection"], :configuring, :internet, %{}})
      assert_receive {:gatt, {:notify, :current_state, <<0x04>>}}
      assert_receive {:redirect_opts, [ifname: "wlan1"]}
    end

    test "wlan0 only reaching :lan (flapping) does NOT mark provisioned" do
      %{mgr: mgr} = start_manager(network_type: offline(), connect_timeout_ms: 10_000)
      assert_receive {:gatt, :register}

      send(mgr, {:improv_rpc_command, submit_frame("MyNet", "pw")})
      assert_receive {:gatt, {:notify, :current_state, <<0x03>>}}

      # :lan (associated, no internet) is not success — a bad password blips it.
      send(mgr, {VintageNet, ["interface", "wlan0", "connection"], :configuring, :lan, %{}})
      refute_receive {:gatt, {:notify, :current_state, <<0x04>>}}, 150
      assert %{state: :provisioning} = Improv.status(mgr)
    end

    test "request-networks notifies one result per network + an empty terminator" do
      %{mgr: mgr} = start_manager(network_type: offline())
      assert_receive {:gatt, :register}

      # request-scanned-networks frame: [0x04][0x00][checksum]
      frame = <<0x04, 0x00, Protocol.checksum(<<0x04, 0x00>>)>>
      send(mgr, {:improv_rpc_command, frame})

      assert_receive {:gatt, {:notify, :rpc_result, net1}}
      assert net1 == Protocol.encode_wifi_network_entry("Net1", -50, true)
      assert_receive {:gatt, {:notify, :rpc_result, net2}}
      assert net2 == Protocol.encode_wifi_network_entry("Net2", -70, false)
      assert_receive {:gatt, {:notify, :rpc_result, term}}
      assert term == Protocol.encode_rpc_result(Protocol.request_networks_command(), [])
    end

    test "a submit that never connects times out → unable-to-connect, reverts to AUTHORIZED" do
      %{mgr: mgr} = start_manager(network_type: offline(), connect_timeout_ms: 100)
      assert_receive {:gatt, :register}

      send(mgr, {:improv_rpc_command, submit_frame("MyNet", "pw")})
      assert_receive {:gatt, {:notify, :current_state, <<0x03>>}}
      assert_receive {:advert, {:set_state, :provisioning}}

      # No connectivity event arrives → connect timer fires; both halves revert.
      assert_receive {:gatt, {:notify, :error_state, <<0x03>>}}, 1000
      assert_receive {:gatt, {:notify, :current_state, <<0x02>>}}, 1000
      assert_receive {:advert, {:set_state, :authorized}}, 1000
      assert %{state: :connected, error: :unable_to_connect} = Improv.status(mgr)
    end

    test "a second submit while provisioning stays in provisioning (re-arms connect timer)" do
      %{mgr: mgr} = start_manager(network_type: offline(), connect_timeout_ms: 10_000)
      assert_receive {:gatt, :register}

      send(mgr, {:improv_rpc_command, submit_frame("MyNet", "pw")})
      assert_receive {:gatt, {:notify, :current_state, <<0x03>>}}

      send(mgr, {:improv_rpc_command, submit_frame("Other", "pw2")})
      assert_receive {:gatt, {:notify, :current_state, <<0x03>>}}
      assert %{state: :provisioning} = Improv.status(mgr)
    end

    test "provisioned hold then teardown disarms" do
      %{mgr: mgr} =
        start_manager(network_type: offline(), provisioned_hold_ms: 60)

      assert_receive {:gatt, :register}
      send(mgr, {:improv_rpc_command, submit_frame("MyNet", "pw")})
      assert_receive {:gatt, {:notify, :current_state, <<0x03>>}}

      send(mgr, {VintageNet, ["interface", "wlan0", "connection"], :configuring, :internet, %{}})
      assert_receive {:gatt, {:notify, :current_state, <<0x04>>}}

      # After the hold, the teardown timer disarms.
      assert_receive {:gatt, :unregister}, 1000
      assert %{state: :disarmed} = Improv.status(mgr)
    end

    test "PROVISIONED with no bound IPv4 pushes no redirect result" do
      %{mgr: mgr} = start_manager(network_type: offline(), wifi: StubWifiNoIp)
      assert_receive {:gatt, :register}

      send(mgr, {:improv_rpc_command, submit_frame("MyNet", "pw")})
      assert_receive {:gatt, {:notify, :current_state, <<0x03>>}}

      send(mgr, {VintageNet, ["interface", "wlan0", "connection"], :configuring, :internet, %{}})
      assert_receive {:gatt, {:notify, :current_state, <<0x04>>}}
      refute_receive {:gatt, {:notify, :rpc_result, _}}, 100
      assert %{state: :provisioned} = Improv.status(mgr)
    end

    test "an unknown command notifies the error-state characteristic" do
      %{mgr: mgr} = start_manager(network_type: offline())
      assert_receive {:gatt, :register}

      # 0x02 = identify (unimplemented), valid checksum.
      frame = <<0x02, 0x00, Protocol.checksum(<<0x02, 0x00>>)>>
      send(mgr, {:improv_rpc_command, frame})

      assert_receive {:gatt, {:notify, :error_state, <<0x02>>}}
      assert %{error: :unknown_command} = Improv.status(mgr)
    end

    test "an invalid submit (empty SSID) notifies invalid-RPC error" do
      %{mgr: mgr} = start_manager(network_type: offline())
      assert_receive {:gatt, :register}

      send(mgr, {:improv_rpc_command, submit_frame("", "pw")})
      assert_receive {:gatt, {:notify, :error_state, <<0x01>>}}
    end
  end

  describe "status/1" do
    test "returns disarmed when the server isn't running" do
      assert Improv.status(:nonexistent_improv_server) == %{state: :disarmed, error: nil}
    end
  end
end
