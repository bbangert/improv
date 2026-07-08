defmodule Improv.GattServerTest do
  use ExUnit.Case, async: true

  alias Improv.GattServer
  alias Improv.Protocol
  alias Bluez.Rebus.Message

  @service_iface "org.bluez.GattService1"
  @char_iface "org.bluez.GattCharacteristic1"
  @om_iface "org.freedesktop.DBus.ObjectManager"
  @props_iface "org.freedesktop.DBus.Properties"
  @introspect_iface "org.freedesktop.DBus.Introspectable"

  # Minimal stand-in for a rebus connection: answers the GenServer.call shapes
  # `Bluez.Rebus.reply`/`emit_signal`/`set_method_handler` make, forwarding every sent
  # message to the test process as `{:sent, %Message{}}`.
  defmodule StubConn do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:send, msg}, _from, test_pid) do
      send(test_pid, {:sent, msg})
      {:reply, :ok, test_pid}
    end

    def handle_call({:set_method_handler, _h}, _from, test_pid), do: {:reply, :ok, test_pid}
  end

  defp start_server(opts \\ []) do
    {:ok, conn} = StubConn.start_link(self())
    {:ok, server} = GattServer.start_link([name: nil, conn: conn, manager: self()] ++ opts)
    %{conn: conn, server: server}
  end

  defp call_in(server, path, interface, member, body, signature) do
    msg =
      Message.new!(:method_call,
        path: path,
        interface: interface,
        member: member,
        body: body,
        signature: signature,
        # bluetoothd's real calls carry a sender; replies derive destination from it.
        sender: ":1.bluez"
      )

    # The transport assigns serials (new! inits to 0); replies need a positive
    # reply_serial, so stamp one as the daemon would.
    send(server, {:dbus_call, %{msg | serial: 1}})
  end

  defp char(key), do: Enum.find(GattServer.chars(), &(&1.key == key))

  describe "managed_objects/2 (tree builder)" do
    test "emits one service + five characteristics with correct ifaces" do
      tree = GattServer.managed_objects(%{}, MapSet.new())

      assert {service_path, [{@service_iface, service_props}]} = hd(tree)
      assert service_path == char(:current_state).path |> Path.dirname()
      assert {"UUID", {"s", Protocol.service_uuid()}} in service_props
      assert {"Primary", {"b", true}} in service_props

      char_objs = tl(tree)
      assert length(char_objs) == 5
      assert Enum.all?(char_objs, fn {_p, [{iface, _}]} -> iface == @char_iface end)
    end

    test "characteristic props carry UUID, Service, Flags and the cached Value" do
      values = %{capabilities: Protocol.capabilities()}
      tree = GattServer.managed_objects(values, MapSet.new())

      cap = char(:capabilities)
      {path, [{@char_iface, props}]} = Enum.find(tree, fn {p, _} -> p == cap.path end)
      assert path == cap.path
      assert {"UUID", {"s", cap.uuid}} in props
      assert {"Flags", {"as", ["read"]}} in props
      # capabilities = 0x04 (scan-wifi bit) surfaced as an `ay` Value.
      assert {"Value", {"ay", [0x04]}} in props
    end

    test "notify chars expose Notifying reflecting the subscription set" do
      cs = char(:current_state)
      tree = GattServer.managed_objects(%{}, MapSet.new([:current_state]))
      {_p, [{@char_iface, props}]} = Enum.find(tree, fn {p, _} -> p == cs.path end)
      assert {"Notifying", {"b", true}} in props
    end

    test "write-only rpc-command has no Value and no Notifying" do
      cmd = char(:rpc_command)
      tree = GattServer.managed_objects(%{rpc_command: <<1, 2>>}, MapSet.new())
      {_p, [{@char_iface, props}]} = Enum.find(tree, fn {p, _} -> p == cmd.path end)
      assert {"Flags", {"as", ["write", "write-without-response"]}} in props
      refute Enum.any?(props, fn {k, _} -> k in ["Value", "Notifying"] end)
    end
  end

  describe "read_value/2" do
    test "returns cached bytes for a readable characteristic" do
      vals = %{capabilities: <<0x04>>}
      assert GattServer.read_value(char(:capabilities).path, vals) == {:ok, [0x04]}
    end

    test "readable characteristic with no cached value reads empty" do
      assert GattServer.read_value(char(:rpc_result).path, %{}) == {:ok, []}
    end

    test "write-only characteristic is NotPermitted" do
      assert GattServer.read_value(char(:rpc_command).path, %{}) ==
               {:error, "org.bluez.Error.NotPermitted"}
    end

    test "unknown path fails" do
      assert {:error, "org.bluez.Error.Failed"} = GattServer.read_value("/nope", %{})
    end
  end

  describe "introspect_xml/1" do
    test "advertises the right interface per object" do
      assert GattServer.introspect_xml(GattServer.app_root()) =~ @om_iface

      assert GattServer.introspect_xml(char(:current_state).path |> Path.dirname()) =~
               @service_iface

      assert GattServer.introspect_xml(char(:rpc_command).path) =~ @char_iface
      refute GattServer.introspect_xml("/nope") =~ "interface name"
    end
  end

  describe "dispatch (GenServer over a stub conn)" do
    test "GetManagedObjects replies the full tree" do
      %{server: server} = start_server()
      call_in(server, GattServer.app_root(), @om_iface, "GetManagedObjects", [], "")

      assert_receive {:sent, %Message{type: :method_return, body: [tree]}}
      # service + 5 chars
      assert length(tree) == 6
    end

    test "Properties.Get returns the requested variant" do
      %{server: server} = start_server()
      cap = char(:capabilities)
      call_in(server, cap.path, @props_iface, "Get", [@char_iface, "UUID"], "ss")

      assert_receive {:sent, %Message{type: :method_return, body: [{"s", uuid}]}}
      assert uuid == cap.uuid
    end

    test "Properties.Set is rejected read-only" do
      %{server: server} = start_server()
      cap = char(:capabilities)
      call_in(server, cap.path, @props_iface, "Set", [@char_iface, "UUID", {"s", "x"}], "ssv")

      assert_receive {:sent,
                      %Message{
                        type: :error,
                        header_fields: %{
                          error_name: "org.freedesktop.DBus.Error.PropertyReadOnly"
                        }
                      }}
    end

    test "ReadValue on capabilities returns scan-only 0x04 by default" do
      %{server: server} = start_server()
      cap = char(:capabilities)
      call_in(server, cap.path, @char_iface, "ReadValue", [[]], "a{sv}")

      assert_receive {:sent, %Message{type: :method_return, body: [[0x04]]}}
    end

    test "ReadValue on capabilities returns the injected derived byte (0x07 full config)" do
      caps = Protocol.capabilities(identify?: true, device_info?: true)
      %{server: server} = start_server(capabilities: caps)
      cap = char(:capabilities)
      call_in(server, cap.path, @char_iface, "ReadValue", [[]], "a{sv}")

      assert_receive {:sent, %Message{type: :method_return, body: [[0x07]]}}
    end

    test "WriteValue forwards identify (0x02) and device-info (0x03) frames" do
      %{server: server} = start_server()
      cmd = char(:rpc_command)

      call_in(server, cmd.path, @char_iface, "WriteValue", [[0x02, 0x00, 0x02], []], "aya{sv}")
      assert_receive {:improv_rpc_command, <<0x02, 0x00, 0x02>>}
      assert_receive {:sent, %Message{type: :method_return}}

      call_in(server, cmd.path, @char_iface, "WriteValue", [[0x03, 0x00, 0x03], []], "aya{sv}")
      assert_receive {:improv_rpc_command, <<0x03, 0x00, 0x03>>}
      assert_receive {:sent, %Message{type: :method_return}}
    end

    test "WriteValue on rpc-command forwards bytes + activity to the manager and acks" do
      %{server: server} = start_server()
      cmd = char(:rpc_command)
      frame = [0x04, 0x00, 0x04]
      call_in(server, cmd.path, @char_iface, "WriteValue", [frame, []], "aya{sv}")

      assert_receive {:improv_rpc_command, <<0x04, 0x00, 0x04>>}
      assert_receive {:improv_client_activity, :rpc_command}
      assert_receive {:sent, %Message{type: :method_return}}
    end

    test "WriteValue on a read-only characteristic is NotPermitted" do
      %{server: server} = start_server()
      cap = char(:capabilities)
      call_in(server, cap.path, @char_iface, "WriteValue", [[0x00], []], "aya{sv}")

      assert_receive {:sent,
                      %Message{
                        type: :error,
                        header_fields: %{error_name: "org.bluez.Error.NotPermitted"}
                      }}
    end

    test "StartNotify subscribes so notify/3 then emits PropertiesChanged" do
      %{server: server} = start_server()
      cs = char(:current_state)
      call_in(server, cs.path, @char_iface, "StartNotify", [], "")

      assert_receive {:improv_client_activity, :current_state}
      assert_receive {:sent, %Message{type: :method_return}}

      GattServer.notify(server, :current_state, Protocol.encode_state(:provisioning))

      assert_receive {:sent,
                      %Message{
                        type: :signal,
                        header_fields: %{member: "PropertiesChanged", path: path},
                        body: [@char_iface, [{"Value", {"ay", [0x03]}}], []]
                      }}

      assert path == cs.path
    end

    test "StopNotify unsubscribes so notify/3 no longer emits" do
      %{server: server} = start_server()
      cs = char(:current_state)

      call_in(server, cs.path, @char_iface, "StartNotify", [], "")
      assert_receive {:sent, %Message{type: :method_return}}

      call_in(server, cs.path, @char_iface, "StopNotify", [], "")
      assert_receive {:sent, %Message{type: :method_return}}

      GattServer.notify(server, :current_state, Protocol.encode_state(:provisioning))
      refute_receive {:sent, %Message{type: :signal}}, 100
    end

    test "StartNotify on a non-notify characteristic is NotSupported" do
      %{server: server} = start_server()
      # capabilities is read-only (no notify flag).
      cap = char(:capabilities)
      call_in(server, cap.path, @char_iface, "StartNotify", [], "")

      assert_receive {:sent,
                      %Message{
                        type: :error,
                        header_fields: %{error_name: "org.bluez.Error.NotSupported"}
                      }}
    end

    test "notify/3 with no subscriber caches without emitting a signal" do
      %{server: server} = start_server()
      GattServer.notify(server, :error_state, Protocol.encode_error(:unable_to_connect))

      refute_receive {:sent, %Message{type: :signal}}, 100

      # The cached value now surfaces on a ReadValue.
      es = char(:error_state)
      call_in(server, es.path, @char_iface, "ReadValue", [[]], "a{sv}")
      assert_receive {:sent, %Message{type: :method_return, body: [[0x03]]}}
    end

    test "Introspect replies XML for the path" do
      %{server: server} = start_server()
      cmd = char(:rpc_command)
      call_in(server, cmd.path, @introspect_iface, "Introspect", [], "")

      assert_receive {:sent, %Message{type: :method_return, body: [xml]}}
      assert xml =~ @char_iface
    end

    test "unknown method gets an UnknownMethod error" do
      %{server: server} = start_server()
      call_in(server, GattServer.app_root(), "org.example.Nope", "Frob", [], "")

      assert_receive {:sent,
                      %Message{
                        type: :error,
                        header_fields: %{error_name: "org.freedesktop.DBus.Error.UnknownMethod"}
                      }}
    end
  end
end
