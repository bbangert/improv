defmodule Improv.WifiTest do
  use ExUnit.Case, async: true

  alias Improv.Wifi

  describe "configure_map/2" do
    test "WPA-PSK network when a password is given" do
      map = Wifi.configure_map("MyNet", "secret12")

      assert %{
               type: VintageNetWiFi,
               vintage_net_wifi: %{networks: [network]},
               ipv4: %{method: :dhcp}
             } = map

      assert network == %{key_mgmt: :wpa_psk, ssid: "MyNet", psk: "secret12"}
    end

    test "open network when the password is empty" do
      map = Wifi.configure_map("OpenAP", "")
      assert %{vintage_net_wifi: %{networks: [network]}} = map
      assert network == %{key_mgmt: :none, ssid: "OpenAP"}
    end
  end

  describe "secured?/1" do
    test "true for WPA/WPA2/PSK/SAE/EAP/WEP and old wpa_* flags" do
      assert Wifi.secured?([:ess, :wpa2, :psk, :ccmp])
      assert Wifi.secured?([:wpa])
      assert Wifi.secured?([:sae])
      assert Wifi.secured?([:eap])
      assert Wifi.secured?([:wep])
      assert Wifi.secured?([:wpa2_psk_ccmp])
    end

    test "false for open networks and non-list flags" do
      refute Wifi.secured?([:ess])
      refute Wifi.secured?([])
      refute Wifi.secured?(nil)
    end
  end

  describe "network_from_ap/1" do
    test "maps ssid / signal_dbm / secured" do
      ap = %{ssid: "Home", signal_dbm: -55, flags: [:ess, :wpa2, :psk]}
      assert Wifi.network_from_ap(ap) == %{ssid: "Home", rssi: -55, secured: true}
    end
  end

  describe "scan_networks/1" do
    test "maps the access_points property, drops empties, dedupes by strongest" do
      # The property is a map bssid => AccessPoint-shaped value.
      aps = %{
        "aa" => %{ssid: "Net1", signal_dbm: -50, flags: [:wpa2, :psk]},
        "bb" => %{ssid: "", signal_dbm: -90, flags: [:ess]},
        "cc" => %{ssid: "Open", signal_dbm: -70, flags: [:ess]},
        # Same SSID as Net1 on another BSSID, stronger — should win.
        "dd" => %{ssid: "Net1", signal_dbm: -40, flags: [:wpa2, :psk]}
      }

      get = fn ["interface", "wlan0", "wifi", "access_points"] -> aps end

      assert {:ok, nets} = Wifi.scan_networks(vintage_get: get, scan_trigger: fn -> :ok end)

      assert nets == [
               %{ssid: "Net1", rssi: -40, secured: true},
               %{ssid: "Open", rssi: -70, secured: false}
             ]
    end

    test "handles an absent property as an empty list" do
      assert {:ok, []} =
               Wifi.scan_networks(vintage_get: fn _ -> nil end, scan_trigger: fn -> :ok end)
    end

    test "ifname: overrides the interface whose property is read" do
      aps = %{"aa" => %{ssid: "Net1", signal_dbm: -50, flags: [:wpa2, :psk]}}
      get = fn ["interface", "wlan1", "wifi", "access_points"] -> aps end

      assert {:ok, [%{ssid: "Net1"}]} =
               Wifi.scan_networks(ifname: "wlan1", vintage_get: get, scan_trigger: fn -> :ok end)
    end

    test "returns {:error, :scan_failed} when the read raises" do
      assert Wifi.scan_networks(
               vintage_get: fn _ -> raise "boom" end,
               scan_trigger: fn -> :ok end
             ) ==
               {:error, :scan_failed}
    end
  end

  describe "configure/3" do
    test "passes the wlan0 config map to the injected configure_fn" do
      test = self()
      cfg = fn ifname, config -> send(test, {:configured, ifname, config}) end

      Wifi.configure("MyNet", "pw", configure_fn: cfg)

      assert_receive {:configured, "wlan0", %{vintage_net_wifi: %{networks: [net]}}}
      assert net == %{key_mgmt: :wpa_psk, ssid: "MyNet", psk: "pw"}
    end

    test "ifname: overrides the configured interface" do
      test = self()
      cfg = fn ifname, config -> send(test, {:configured, ifname, config}) end

      Wifi.configure("MyNet", "pw", configure_fn: cfg, ifname: "wlan1")

      assert_receive {:configured, "wlan1", _config}
    end
  end

  describe "redirect_url/1" do
    test "builds an http URL from the wlan0 IPv4 address" do
      get = fn ["interface", "wlan0", "addresses"] ->
        [%{family: :inet, scope: :universe, address: {192, 168, 1, 50}}]
      end

      assert Wifi.redirect_url(vintage_get: get) == "http://192.168.1.50/"
    end

    test "ifname: overrides the interface whose addresses are read" do
      get = fn ["interface", "wlan1", "addresses"] ->
        [%{family: :inet, scope: :universe, address: {10, 0, 0, 7}}]
      end

      assert Wifi.redirect_url(ifname: "wlan1", vintage_get: get) == "http://10.0.0.7/"
    end

    test "nil when no IPv4 address is bound" do
      assert Wifi.redirect_url(vintage_get: fn _ -> [] end) == nil
      assert Wifi.redirect_url(vintage_get: fn _ -> nil end) == nil
    end
  end
end
