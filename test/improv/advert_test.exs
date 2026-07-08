defmodule Improv.AdvertTest do
  use ExUnit.Case, async: true

  alias Improv.Advert
  alias Improv.Protocol
  alias Bluez.Rebus.Message

  @adv_iface "org.bluez.LEAdvertisement1"
  @props_iface "org.freedesktop.DBus.Properties"
  @introspect_iface "org.freedesktop.DBus.Introspectable"

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

  defp start_advert(opts \\ []) do
    {:ok, conn} = StubConn.start_link(self())
    {:ok, server} = Advert.start_link([name: nil, conn: conn] ++ opts)
    %{conn: conn, server: server}
  end

  defp call_in(server, interface, member, body, signature) do
    msg =
      Message.new!(:method_call,
        path: Advert.adv_path(),
        interface: interface,
        member: member,
        body: body,
        signature: signature,
        sender: ":1.bluez"
      )

    send(server, {:dbus_call, %{msg | serial: 1}})
  end

  describe "advertisement_props/2 (pure)" do
    test "carries Type, ServiceUUIDs, ServiceData, LocalName, Discoverable" do
      props = Advert.advertisement_props("Living Room")

      assert {"Type", {"s", "peripheral"}} in props
      assert {"ServiceUUIDs", {"as", [Protocol.service_uuid()]}} in props
      assert {"LocalName", {"s", "Living Room"}} in props
      assert {"Discoverable", {"b", true}} in props

      # The spec's 6-byte payload keyed by the 16-bit UUID: state frozen at
      # AUTHORIZED (0x02), default capabilities scan-only (0x04), 4 reserved.
      assert List.keyfind(props, "ServiceData", 0) ==
               {"ServiceData", {"a{sv}", [{"4677", {"ay", [0x02, 0x04, 0, 0, 0, 0]}}]}}
    end

    test "ServiceData carries the derived capabilities byte" do
      caps = Protocol.capabilities(identify?: true, device_info?: true)
      props = Advert.advertisement_props("Living Room", caps)

      assert {"ServiceData", {"a{sv}", [{"4677", {"ay", [0x02, 0x07, 0, 0, 0, 0]}}]}} =
               List.keyfind(props, "ServiceData", 0)
    end
  end

  describe "introspect_xml/1" do
    test "advertises LEAdvertisement1 at the advert path only" do
      assert Advert.introspect_xml(Advert.adv_path()) =~ @adv_iface
      refute Advert.introspect_xml("/nope") =~ "interface name"
    end
  end

  describe "dispatch over a stub conn" do
    test "GetAll returns the advertisement properties" do
      %{server: server} = start_advert(local_name: "TestDev")
      call_in(server, @props_iface, "GetAll", [@adv_iface], "s")

      assert_receive {:sent, %Message{type: :method_return, body: [props]}}
      assert {"LocalName", {"s", "TestDev"}} in props
      assert {"Type", {"s", "peripheral"}} in props
    end

    test "defaults to the neutral \"Improv <suffix>\" local name" do
      %{server: server} = start_advert()
      call_in(server, @props_iface, "Get", [@adv_iface, "LocalName"], "ss")

      assert_receive {:sent, %Message{type: :method_return, body: [{"s", name}]}}
      assert ["Improv", suffix] = String.split(name, " ", parts: 2)
      assert suffix != ""
    end

    test "name_prefix: rebrands the local name while keeping the device suffix" do
      %{server: server} = start_advert(name_prefix: "Universal Proxy")
      call_in(server, @props_iface, "Get", [@adv_iface, "LocalName"], "ss")

      assert_receive {:sent, %Message{type: :method_return, body: [{"s", name}]}}
      assert "Universal Proxy " <> suffix = name
      assert suffix != ""
    end

    test "Get returns a single property variant" do
      %{server: server} = start_advert()
      call_in(server, @props_iface, "Get", [@adv_iface, "Type"], "ss")

      assert_receive {:sent, %Message{type: :method_return, body: [{"s", "peripheral"}]}}
    end

    test "Get of an unknown property errors" do
      %{server: server} = start_advert()
      call_in(server, @props_iface, "Get", [@adv_iface, "Nope"], "ss")

      assert_receive {:sent,
                      %Message{
                        type: :error,
                        header_fields: %{error_name: "org.freedesktop.DBus.Error.UnknownProperty"}
                      }}
    end

    test "Set is rejected read-only" do
      %{server: server} = start_advert()
      call_in(server, @props_iface, "Set", [@adv_iface, "Type", {"s", "x"}], "ssv")

      assert_receive {:sent,
                      %Message{
                        type: :error,
                        header_fields: %{
                          error_name: "org.freedesktop.DBus.Error.PropertyReadOnly"
                        }
                      }}
    end

    test "Release is acked" do
      %{server: server} = start_advert()
      call_in(server, @adv_iface, "Release", [], "")

      assert_receive {:sent, %Message{type: :method_return}}
    end

    test "Introspect replies XML" do
      %{server: server} = start_advert()
      call_in(server, @introspect_iface, "Introspect", [], "")

      assert_receive {:sent, %Message{type: :method_return, body: [xml]}}
      assert xml =~ @adv_iface
    end

    test "set_state is a no-op (ServiceData is static) and never emits or crashes" do
      %{server: server} = start_advert()
      Advert.set_state(server, :provisioning)
      Advert.set_state(server, :bogus)

      # No PropertiesChanged signal is emitted...
      refute_receive {:sent, %Message{type: :signal}}, 100

      # ...and the server is still alive and answering, ServiceData still
      # frozen at AUTHORIZED (0x02) — registration-time static.
      call_in(server, @props_iface, "GetAll", [@adv_iface], "s")
      assert_receive {:sent, %Message{type: :method_return, body: [props]}}

      assert {"ServiceData", {"a{sv}", [{"4677", {"ay", [0x02 | _]}}]}} =
               List.keyfind(props, "ServiceData", 0)

      assert {"Type", {"s", "peripheral"}} in props
    end

    test "unknown method gets UnknownMethod" do
      %{server: server} = start_advert()
      call_in(server, "org.example.X", "Frob", [], "")

      assert_receive {:sent,
                      %Message{
                        type: :error,
                        header_fields: %{error_name: "org.freedesktop.DBus.Error.UnknownMethod"}
                      }}
    end
  end
end
