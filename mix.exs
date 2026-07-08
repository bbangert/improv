defmodule Improv.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/bbangert/improv"

  def project do
    [
      app: :improv,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        # Optional deps' types are needed to check the guarded call sites.
        plt_add_apps: [:phoenix_pubsub, :vintage_net]
      ],
      description:
        "Improv-over-BLE Wi-Fi provisioning for Elixir/Nerves devices, on BlueZ over D-Bus",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bluez, "~> 0.1"},
      {:phoenix_pubsub, "~> 2.1", optional: true},
      # runtime: false so the lib's own dev/test runs never START vintage_net
      # (it writes /etc/resolv.conf at startup — host-hostile). Guarded call
      # sites ensure_all_started it on demand; consumers that want the
      # built-in backend depend on vintage_net directly (Nerves apps do).
      {:vintage_net, "~> 0.13", optional: true, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md"],
      groups_for_modules: [
        Manager: [Improv, Improv.Supervisor],
        "GATT + advertisement transport": [Improv.GattServer, Improv.Advert, Improv.Protocol],
        "Wi-Fi backend": [Improv.Wifi]
      ]
    ]
  end
end
