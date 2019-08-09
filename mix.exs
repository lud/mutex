defmodule Mutex.Mixfile do
  use Mix.Project

  def project do
    [
      app: :mutex,
      description: """
      This package implements a simple mutex as a GenServer. It allows to await
      locked keys and handles locking multiple keys without deadlocks.
      """,
      version: "1.0.2",
      elixir: "~> 1.4",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Mutex",
      docs: [
        main: "readme",
        extras: ["README.md"]
      ],
      package: package()
    ]
  end

  def application do
    # Specify extra applications you'll use from Erlang/Elixir
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.14", only: :dev, runtime: false},
      {:dogma, "~> 0.1.15", only: :dev},
      {:dialyxir, "~> 0.4", only: :dev, runtime: false}
    ]
  end

  defp package() do
    [
      licenses: ["MIT"],
      maintainers: ["niahoo osef <dev@ooha.in>"],
      links: %{"Github" => "https://github.com/niahoo/mutex"}
    ]
  end
end
