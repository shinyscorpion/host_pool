defmodule HostPool.Mixfile do
  use Mix.Project

  def project do
    [
      app: :host_pool,
      version: "0.0.1",
      elixir: "~> 1.5",
      start_permanent: Mix.env == :prod,
      deps: deps(),
      package: package(),

      # Docs
      name: "HostPool",
      source_url: "https://github.com/shinyscorpion/host_pool",
      homepage_url: "https://github.com/shinyscorpion/host_pool",
      docs: [
        main: "readme",
        extras: ["README.md"],
      ],

      # Testing
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: ["coveralls": :test, "coveralls.detail": :test, "coveralls.post": :test, "coveralls.html": :test],
      dialyzer: [plt_add_deps: :project, plt_add_apps: []],
    ]
  end

  def package do
    [
      name: :host_pool,
      maintainers: ["Ian Luites"],
      licenses: ["MIT"],
      files: [
        "lib", "mix.exs", "README*", "LICENSE*", # Elixir
      ],
      links: %{
        "GitHub" => "https://github.com/shinyscorpion/host_pool",
      },
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Sadly need to go the git route until hackney is fixed
      {:hackney, "~> 1.9", github: "ianluites/hackney", branch: "fix/hackney-pool-handler-connect", override: true},

      # Dev / Test
      {:analyze, "~> 0.0", runtime: false, only: [:dev, :test]},
      {:meck, "~> 0.8", only: :test},
    ]
  end
end
