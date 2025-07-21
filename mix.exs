defmodule VsmConnections.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/viable-systems/vsm-connections"

  def project do
    [
      app: :vsm_connections,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      preferred_cli_env: [
        "test.all": :test,
        "test.integration": :test,
        "test.unit": :test
      ],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix]
      ],
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {VsmConnections.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # HTTP client and connection pooling
      {:finch, "~> 0.18"},
      {:poolboy, "~> 1.5"},
      {:httpoison, "~> 2.0"},
      
      # WebSocket support
      {:websockex, "~> 0.4"},
      {:gun, "~> 2.0"},
      
      # gRPC support
      {:grpc, "~> 0.8"},
      {:cowlib, "~> 2.12", override: true},
      
      # Circuit breaker pattern
      {:fuse, "~> 2.5"},
      
      # Health checking and monitoring
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      
      # Redis integration
      {:redix, "~> 1.3"},
      
      # JSON handling
      {:jason, "~> 1.4"},
      
      # Time and scheduling
      {:quantum, "~> 3.5"},
      
      # Retry mechanisms
      {:retry, "~> 0.18"},
      
      # Async processing
      {:broadway, "~> 1.0"},
      {:gen_stage, "~> 1.2"},
      
      # Development and testing dependencies
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:mix_test_watch, "~> 1.0", only: [:dev, :test], runtime: false},
      
      # Mocking and testing utilities
      {:mox, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:stream_data, "~> 0.6", only: [:dev, :test]},
      
      # Benchmarking
      {:benchee, "~> 1.1", only: [:dev, :test]}
    ]
  end

  defp description do
    "VSM Connection Infrastructure providing pool management, circuit breakers, health checking, and multi-protocol support for Viable Systems Model implementations."
  end

  defp package do
    [
      files: ~w(lib .formatter.exs mix.exs README* CHANGELOG* LICENSE*),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Viable Systems" => "https://github.com/viable-systems"
      },
      maintainers: ["Viable Systems Team"]
    ]
  end

  defp docs do
    [
      main: "VsmConnections",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        "Core Components": [
          VsmConnections,
          VsmConnections.Application,
          VsmConnections.Config
        ],
        "Connection Management": [
          VsmConnections.Pool,
          VsmConnections.Pool.Manager,
          VsmConnections.Pool.Worker,
          VsmConnections.Pool.Supervisor
        ],
        "Circuit Breakers": [
          VsmConnections.CircuitBreaker,
          VsmConnections.CircuitBreaker.Config,
          VsmConnections.CircuitBreaker.State
        ],
        "Health Checking": [
          VsmConnections.HealthCheck,
          VsmConnections.HealthCheck.Monitor,
          VsmConnections.HealthCheck.Scheduler
        ],
        "Protocol Adapters": [
          VsmConnections.Adapters.HTTP,
          VsmConnections.Adapters.WebSocket,
          VsmConnections.Adapters.GRPC
        ],
        "Redis Integration": [
          VsmConnections.Redis,
          VsmConnections.Redis.Cluster,
          VsmConnections.Redis.PubSub
        ],
        "Fault Tolerance": [
          VsmConnections.FaultTolerance,
          VsmConnections.FaultTolerance.Retry,
          VsmConnections.FaultTolerance.Backoff
        ]
      ]
    ]
  end
end