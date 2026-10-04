defmodule Improv.Wifi do
  @moduledoc """
  Wi-Fi operations for Improv provisioning: scan for networks, apply submitted
  credentials, and derive the post-provisioning redirect URL. The seam the
  `Improv` manager calls into.

  All VintageNet access is guarded (`Code.ensure_loaded?`) so the module loads on
  host, and is injectable (`:scan_trigger` / `:vintage_get` / `:configure_fn`) so
  the pure shaping — the configure map, the AP→network mapping, the secured? rule —
  is host-tested without a radio. The Wi-Fi interface defaults to `"wlan0"`;
  pass `ifname:` in each call's opts to target another interface.

  `scan_networks/1` reads the live `access_points` property (kept fresh by
  `wpa_supplicant`) rather than `VintageNetWiFi.quick_scan/1`, whose fresh-scan +
  2 s sleep read an empty list mid-scan on hardware. It also kicks an async
  `VintageNet.scan/1` to refresh the property for the next call.

  Improv only carries SSID+password, not a security type, so `configure/3`
  infers `key_mgmt: :sae` (WPA3) vs `:wpa_psk` from the target SSID's scan
  flags — PSK is the fallback whenever the SSID isn't in scan results (hidden
  network, aged out) or the lookup itself fails.
  """

  require Logger

  @default_ifname "wlan0"

  # AP `:flags` that indicate a secured network (new-style; old-style wpa_* flags
  # are matched by prefix). Anything else (e.g. `[:ess]`) is open.
  @security_flags [:psk, :eap, :sae, :wep, :wpa, :wpa2]

  @type network :: %{ssid: binary(), rssi: integer(), secured: boolean()}

  @doc """
  Nearby networks → `{:ok, [network]}` (empty SSIDs dropped, deduped by SSID
  keeping the strongest signal), or `{:error, reason}`.

  Reads the live `["interface", ifname, "wifi", "access_points"]` property that
  `wpa_supplicant` keeps refreshed via periodic background scans — NOT
  `VintageNetWiFi.quick_scan/1`, which triggers a fresh ioctl scan and only waits
  2s, so it lands in the empty window mid-scan (HW-found: returned 0 while the
  property held 31 APs). We also kick an async `VintageNet.scan/1` to keep the
  property fresh for the next request. `:vintage_get`/`:scan_trigger` injectable.
  """
  @spec scan_networks(keyword()) :: {:ok, [network()]} | {:error, term()}
  def scan_networks(opts \\ []) do
    ifname = Keyword.get(opts, :ifname, @default_ifname)
    get = Keyword.get(opts, :vintage_get, &vintage_get/1)
    trigger = Keyword.get(opts, :scan_trigger, fn -> default_scan_trigger(ifname) end)

    # Async refresh for subsequent requests; return what's cached now.
    trigger.()

    networks =
      ["interface", ifname, "wifi", "access_points"]
      |> get.()
      |> ap_list()
      |> Enum.map(&network_from_ap/1)
      |> Enum.reject(&(&1.ssid in [nil, ""]))
      |> Enum.sort_by(& &1.rssi, :desc)
      |> Enum.uniq_by(& &1.ssid)

    {:ok, networks}
  rescue
    # printable_limit bounds the log — exception args on this path can carry
    # peer-influenced data, and the same bound keeps any credential-bearing
    # exception (see the manager's safe_apply/3) out of persisted logs.
    e ->
      Logger.warning("Improv.Wifi: scan failed: #{inspect(e, limit: 5, printable_limit: 200)}")
      {:error, :scan_failed}
  end

  defp ap_list(aps) when is_map(aps), do: Map.values(aps)
  defp ap_list(aps) when is_list(aps), do: aps
  defp ap_list(_), do: []

  @doc """
  Apply submitted credentials to the Wi-Fi interface. Looks up the target
  SSID's live scan flags (union across every BSSID advertising that SSID) to
  pick `key_mgmt: :sae` vs `:wpa_psk` — see `configure_map/3`. The lookup is
  best-effort: a raise, a nil property, or the SSID simply not appearing in
  scan results all fall back to `[]` (the PSK path) rather than failing the
  call. The flags come from the same live property `scan_networks/1` reads,
  so the usual scan-then-submit provisioning flow keeps them fresh; a submit
  with no recent scan can miss a just-appeared SAE-only network and fall
  back to PSK. `:vintage_get` (the lookup) and `:configure_fn` (2-arity
  `(ifname, config) -> term`) are injectable for tests.
  """
  @spec configure(binary(), binary(), keyword()) :: term()
  def configure(ssid, password, opts \\ []) do
    ifname = Keyword.get(opts, :ifname, @default_ifname)
    get = Keyword.get(opts, :vintage_get, &vintage_get/1)
    cfg = Keyword.get(opts, :configure_fn, &default_configure/2)

    flags = ssid_flags(ifname, ssid, get)

    cfg.(ifname, configure_map(ssid, password, flags))
  end

  # Union of `:flags` across every AP (BSSID) advertising `ssid` in the live
  # access_points property. If ANY BSS mentions psk, that ends up in the
  # union too, so `sae_only?/1` comes back false and we keep the
  # broad-compatibility PSK path — deliberate for multi-band APs / transition
  # mode. Any raise (bad get, malformed property) falls back to `[]` — logged,
  # since a silent failure here reverts SAE-only networks to the PSK bug.
  defp ssid_flags(ifname, ssid, get) do
    ["interface", ifname, "wifi", "access_points"]
    |> get.()
    |> ap_list()
    |> Enum.filter(&(Map.get(&1, :ssid) == ssid))
    |> Enum.flat_map(&Map.get(&1, :flags, []))
    |> Enum.uniq()
  rescue
    # Same printable_limit bound as scan_networks/1: the exception can carry
    # peer-influenced data (the submitted SSID); no password is in scope here.
    e ->
      Logger.warning(
        "Improv.Wifi: flags lookup failed, assuming PSK: #{inspect(e, limit: 5, printable_limit: 200)}"
      )

      []
  end

  @doc """
  The web-UI URL to hand back to the provisioner once joined, or `nil` if no
  IPv4 address is bound yet. `:vintage_get` injectable for tests.
  """
  @spec redirect_url(keyword()) :: String.t() | nil
  def redirect_url(opts \\ []) do
    ifname = Keyword.get(opts, :ifname, @default_ifname)
    get = Keyword.get(opts, :vintage_get, &vintage_get/1)
    addrs = get.(["interface", ifname, "addresses"]) || []

    case first_ipv4(addrs) do
      nil -> nil
      ip -> "http://#{ip}/"
    end
  end

  # ── pure shaping (host-tested) ─────────────────────────────────────────────

  @doc """
  VintageNet config map for a submitted SSID/password. An empty password
  yields an open (`key_mgmt: :none`) network; otherwise `key_mgmt: :sae`
  (WPA3, with mandatory PMF — `ieee80211w: 2`) if `flags` say the SSID is
  SAE-only, else the broad-compatibility `:wpa_psk` fallback (also used for
  hidden networks, SSIDs that aged out of scan results, and WPA2/WPA3
  transition-mode networks, which still accept PSK). `flags` is threaded in
  by the caller (`configure/3`, from a live scan) — this function itself
  stays pure and does no lookups.
  """
  @spec configure_map(binary(), binary(), [atom()]) :: map()
  def configure_map(ssid, password, flags \\ []) do
    network =
      cond do
        password == "" ->
          %{key_mgmt: :none, ssid: ssid}

        sae_only?(flags) ->
          %{key_mgmt: :sae, ssid: ssid, sae_password: password, ieee80211w: 2}

        true ->
          %{key_mgmt: :wpa_psk, ssid: ssid, psk: password}
      end

    %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{networks: [network]},
      ipv4: %{method: :dhcp}
    }
  end

  @doc "Map a `VintageNetWiFi.AccessPoint`-shaped value to a `t:network/0`. Pure."
  @spec network_from_ap(map()) :: network()
  def network_from_ap(%{ssid: ssid, signal_dbm: dbm, flags: flags}) do
    %{ssid: ssid, rssi: dbm, secured: secured?(flags)}
  end

  @doc "Whether an AP's `:flags` indicate a secured network. Pure."
  @spec secured?([atom()] | term()) :: boolean()
  def secured?(flags) when is_list(flags) do
    Enum.any?(flags, fn f -> f in @security_flags or wpa_old_flag?(f) end)
  end

  def secured?(_), do: false

  defp wpa_old_flag?(f) when is_atom(f), do: f |> Atom.to_string() |> String.starts_with?("wpa")
  defp wpa_old_flag?(_), do: false

  # SAE-only (WPA3-only): at least one flag mentions "sae" and none mention
  # "psk". Substring match (not membership) so this covers both decomposed
  # flags (`:sae`, `:psk`) and compound ones (`:wpa2_sae_ccmp`,
  # `:wpa2_psk_sae_ccmp`) the same way `wpa_old_flag?/1` prefix-matches
  # old-style `wpa_*` flags. A network in transition mode mentions both, so
  # it falls through to the PSK path — deliberately, for broad compatibility.
  defp sae_only?(flags) when is_list(flags) do
    Enum.any?(flags, &flag_mentions?(&1, "sae")) and
      not Enum.any?(flags, &flag_mentions?(&1, "psk"))
  end

  defp sae_only?(_), do: false

  defp flag_mentions?(flag, keyword) when is_atom(flag),
    do: flag |> Atom.to_string() |> String.contains?(keyword)

  defp flag_mentions?(_, _), do: false

  defp first_ipv4(addrs) when is_list(addrs) do
    Enum.find_value(addrs, fn
      %{family: :inet, scope: :universe, address: {_, _, _, _} = tuple} ->
        tuple |> Tuple.to_list() |> Enum.join(".")

      _ ->
        nil
    end)
  end

  defp first_ipv4(_), do: nil

  # ── VintageNet wrappers (target-only) ──────────────────────────────────────

  # These use apply/3 on purpose: vintage_net is an optional dep, so a literal
  # remote call would warn "VintageNet.x/n is undefined" when a consumer
  # compiles improv without it (hence the per-line credo disables).

  # Best-effort async refresh of the access_points property; results land later.
  defp default_scan_trigger(ifname) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    if Code.ensure_loaded?(VintageNet), do: apply(VintageNet, :scan, [ifname]), else: :ok
  rescue
    _ -> :ok
  end

  defp default_configure(ifname, config) do
    # VintageNet.configure/2 takes the bare ifname ("wlan0"), NOT a property path
    # (["interface","wlan0"] is only for VintageNet.get) — the latter raises
    # ArgumentError "Invalid property element" (HW-found: configure never applied,
    # so provisioning always timed out as unable-to-connect).
    if Code.ensure_loaded?(VintageNet) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(VintageNet, :configure, [ifname, config])
    else
      {:error, :vintage_net_unavailable}
    end
  end

  defp vintage_get(path) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    if Code.ensure_loaded?(VintageNet), do: apply(VintageNet, :get, [path]), else: nil
  end
end
