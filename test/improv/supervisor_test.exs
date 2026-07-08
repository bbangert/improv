defmodule Improv.SupervisorTest do
  use ExUnit.Case, async: true

  @device_info [
    firmware_name: "Fw",
    firmware_version: "1.2.3",
    hardware: "HW",
    device_name: "Dev 507f"
  ]

  # The derivation invariant: the capabilities byte is computed ONCE from the
  # identify_fun/device_info opts and handed to BOTH exporters, so the GATT
  # capabilities characteristic and the advertisement ServiceData can never
  # disagree. 0x04 = scan (always on), 0x01 = identify, 0x02 = device-info.
  @combos [
    {[], 0x04},
    {[identify_fun: &__MODULE__.noop/0], 0x05},
    {[device_info: @device_info], 0x06},
    {[identify_fun: &__MODULE__.noop/0, device_info: @device_info], 0x07}
  ]

  def noop, do: :ok

  defp init(opts) do
    {:ok, {sup_flags, children}} = Improv.Supervisor.init(opts)
    {sup_flags, children}
  end

  defp start_opts(children, mod) do
    %{start: {^mod, :start_link, [opts]}} = Enum.find(children, &(&1.id == mod))
    opts
  end

  test "GattServer and Advert always receive the same derived capabilities byte" do
    for {opts, expected} <- @combos do
      {_flags, children} = init(opts ++ [name_prefix: "Test Device"])

      gatt_opts = start_opts(children, Improv.GattServer)
      advert_opts = start_opts(children, Improv.Advert)

      assert Keyword.fetch!(gatt_opts, :capabilities) == <<expected>>,
             "gatt capabilities for #{inspect(opts)}"

      assert Keyword.fetch!(advert_opts, :capabilities) == <<expected>>,
             "advert capabilities for #{inspect(opts)}"
    end
  end

  test "branding opts land only in Advert's opts" do
    {_flags, children} =
      init(name_prefix: "Test Device", local_name: "Test Device 507f", identify_fun: &noop/0)

    advert_opts = start_opts(children, Improv.Advert)
    assert Keyword.fetch!(advert_opts, :name_prefix) == "Test Device"
    assert Keyword.fetch!(advert_opts, :local_name) == "Test Device 507f"

    gatt_opts = start_opts(children, Improv.GattServer)
    manager_opts = start_opts(children, Improv)

    for key <- [:name_prefix, :local_name] do
      refute Keyword.has_key?(gatt_opts, key)
      refute Keyword.has_key?(manager_opts, key)
    end

    # The manager keeps its own opts (they're what's left after the split).
    assert Keyword.has_key?(manager_opts, :identify_fun)
  end

  test "strategy is :one_for_all and the manager starts last" do
    {flags, children} = init([])

    assert flags.strategy == :one_for_all
    assert children |> List.last() |> Map.fetch!(:id) == Improv
  end
end
