defmodule Mutex.Mixfile do
  use Mix.Project

  @source_url "https://github.com/lud/mutex"
  @version "2.0.0"

  def project do
    [
      app: :mutex,
      version: @version,
      elixir: "~> 1.15",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      name: "Mutex",
      package: package(),
      versioning: versioning(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    # Specify extra applications you'll use from Erlang/Elixir
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.2", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: :dev, runtime: false}
    ]
  end

  defp package() do
    [
      description:
        "This package implements a simple mutex as a GenServer. " <>
          "It allows to lock keys and handles locking multiple keys " <>
          "without deadlocks.",
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
      formatters: ["html"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp versioning do
    [
      annotate: true,
      before_commit: [
        fn vsn ->
          case System.cmd("git", ["cliff", "--tag", vsn, "-o", "CHANGELOG.md"], stderr_to_stdout: true) do
            {_, 0} -> IO.puts("Updated CHANGELOG.md with #{vsn}")
            {out, _} -> {:error, "Could not update CHANGELOG.md:\n\n #{out}"}
          end
        end,
        add: "CHANGELOG.md"
      ]
    ]
  end
end
