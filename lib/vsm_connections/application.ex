defmodule VsmConnections.Application do
  @moduledoc """
  Application module for VSM Connections infrastructure.
  
  This module is responsible for starting and managing the supervision tree
  for the VSM connections infrastructure, including:
  
  - Connection pools for different protocols
  - Circuit breakers for fault tolerance
  - Health checking systems
  - Redis integration for distributed state
  - Telemetry and monitoring
  """

  use Application

  alias VsmConnections.Pool.Supervisor, as: PoolSupervisor
  alias VsmConnections.CircuitBreaker.Supervisor, as: CircuitBreakerSupervisor
  alias VsmConnections.HealthCheck.Supervisor, as: HealthCheckSupervisor
  alias VsmConnections.Redis.Supervisor, as: RedisSupervisor

  @impl true
  def start(_type, _args) do
    # Define the supervision tree
    children = [
      # Configuration manager
      VsmConnections.Config,
      
      # Telemetry and metrics
      {TelemetryMetrics.Supervisor, telemetry_metrics()},
      {Telemetry.Poller, telemetry_poller_opts()},
      
      # Core infrastructure supervisors
      {PoolSupervisor, []},
      {CircuitBreakerSupervisor, []},
      {HealthCheckSupervisor, []},
      {RedisSupervisor, []},
      
      # Finch HTTP client pool
      {Finch, name: VsmConnections.Finch, pools: finch_pools()},
      
      # Fault tolerance scheduler
      {VsmConnections.FaultTolerance.Scheduler, []},
      
      # VSM telemetry reporter for integration with VSM Core
      {VsmConnections.VSMTelemetryReporter, []}
    ]

    opts = [strategy: :one_for_one, name: VsmConnections.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Telemetry metrics configuration
  defp telemetry_metrics do
    [
      # Connection pool metrics
      Telemetry.Metrics.counter("vsm_connections.pool.checkout",
        tags: [:pool_name, :protocol]
      ),
      Telemetry.Metrics.counter("vsm_connections.pool.checkin",
        tags: [:pool_name, :protocol]
      ),
      Telemetry.Metrics.distribution("vsm_connections.pool.wait_time",
        tags: [:pool_name, :protocol],
        unit: {:native, :millisecond}
      ),
      
      # Circuit breaker metrics
      Telemetry.Metrics.counter("vsm_connections.circuit_breaker.state_change",
        tags: [:name, :from_state, :to_state]
      ),
      Telemetry.Metrics.counter("vsm_connections.circuit_breaker.call",
        tags: [:name, :result]
      ),
      
      # Health check metrics
      Telemetry.Metrics.counter("vsm_connections.health_check.result",
        tags: [:service, :result]
      ),
      Telemetry.Metrics.distribution("vsm_connections.health_check.duration",
        tags: [:service],
        unit: {:native, :millisecond}
      ),
      
      # Protocol adapter metrics
      Telemetry.Metrics.counter("vsm_connections.adapter.request",
        tags: [:adapter, :method, :status]
      ),
      Telemetry.Metrics.distribution("vsm_connections.adapter.duration",
        tags: [:adapter, :method],
        unit: {:native, :millisecond}
      ),
      
      # Redis metrics
      Telemetry.Metrics.counter("vsm_connections.redis.command",
        tags: [:command, :result]
      ),
      Telemetry.Metrics.distribution("vsm_connections.redis.duration",
        tags: [:command],
        unit: {:native, :millisecond}
      ),
      
      # Fault tolerance metrics
      Telemetry.Metrics.counter("vsm_connections.retry.attempt",
        tags: [:operation, :attempt]
      ),
      Telemetry.Metrics.counter("vsm_connections.retry.result",
        tags: [:operation, :result]
      )
    ]
  end

  # Telemetry poller configuration
  defp telemetry_poller_opts do
    [
      measurements: [
        # Pool stats
        {VsmConnections.Pool, :get_pool_stats, []},
        
        # Circuit breaker stats
        {VsmConnections.CircuitBreaker, :get_stats, []},
        
        # Redis connection stats
        {VsmConnections.Redis, :get_connection_stats, []},
        
        # System stats
        {:erlang, :memory, []},
        {:erlang, :system_info, [:process_count]}
      ],
      period: :timer.seconds(10)
    ]
  end

  # Finch connection pools configuration
  defp finch_pools do
    config = VsmConnections.Config.get(:pools, %{})
    
    Enum.map(config, fn {pool_name, pool_config} ->
      {String.to_atom(pool_config[:host] || "localhost"), 
       pool_config
       |> Map.put(:size, pool_config[:size] || 10)
       |> Map.put(:count, pool_config[:count] || 1)}
    end)
  end
end