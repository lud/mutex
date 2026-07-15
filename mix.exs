defmodule Mutex.Mixfile do
  use Mix.Project

  @source_url "https://github.com/lud/mutex"
  @version "4.1.0"

  def project do
    [
      app: :mutex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      name: "Mutex",
      description:
        "This package implements a simple mutex as a GenServer. " <>
          "It allows to lock keys and handles locking multiple keys " <>
          "without deadlocks.",
      source_url: @source_url,
      package: package(),
      versioning: versioning(),
      dialyzer: dialyzer(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    # Specify extra applications you'll use from Erlang/Elixir
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Dev
      {:libdev, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:readmix, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp package() do
    [
      licenses: ["MIT"],
      maintainers: ["Ludovic Demblans <ludovic@demblans.com>"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      extras: [
        "README.md": [title: "Overview"],
        "LICENSE.md": [title: "License"]
      ],
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      formatters: ["html", "markdown"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp versioning do
    [
      annotate: true,
      before_commit: [
        &update_readme/1,
        {:add, "README.md"},
        &gen_changelog/1,
        {:add, "CHANGELOG.md"}
      ]
    ]
  end

  defp update_readme(vsn) do
    :ok = Readmix.update_file(Readmix.new(vars: %{app_vsn: vsn}), "README.md")
    :ok
  end

  defp gen_changelog(vsn) do
    case System.cmd("git", ["cliff", "--tag", vsn, "-o", "CHANGELOG.md"], stderr_to_stdout: true) do
      {_, 0} -> IO.puts("Updated CHANGELOG.md with #{vsn}")
      {out, _} -> {:error, "Could not update CHANGELOG.md:\n\n #{out}"}
    end
  end

  defp dialyzer do
    [
      flags: [:unmatched_returns, :error_handling, :unknown, :extra_return],
      list_unused_filters: true,
      plt_add_apps: [:ex_unit],
      plt_local_path: "_build/plts"
    ]
  end

  def cli do
    [
      preferred_envs: [dialyzer: :test]
    ]
  end
end
