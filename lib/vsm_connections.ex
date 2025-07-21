defmodule VsmConnections do
  @moduledoc """
  VSM Connections Infrastructure
  
  This module provides the main API for the VSM connections infrastructure,
  offering pool management, circuit breakers, health checking, and multi-protocol
  support for Viable Systems Model implementations.
  
  ## Core Features
  
  - **Connection Pooling**: Efficient pool management using Finch and Poolboy
  - **Circuit Breakers**: Fault tolerance through circuit breaker patterns
  - **Health Checking**: Automated health monitoring for services
  - **Multi-Protocol Support**: HTTP, WebSocket, and gRPC adapters
  - **Redis Integration**: Distributed state management
  - **Fault Tolerance**: Comprehensive retry and backoff mechanisms
  
  ## VSM Integration
  
  This infrastructure integrates with the broader VSM ecosystem to provide:
  
  - **System 1 Operations**: Reliable service-to-service communication
  - **System 2 Coordination**: Connection coordination and load balancing
  - **System 3 Control**: Performance monitoring and resource management
  - **System 4 Intelligence**: Adaptive connection strategies
  - **Algedonic Channels**: Emergency communication pathways
  
  ## Quick Start
  
      # Start with default configuration
      {:ok, _} = VsmConnections.start()
      
      # Make an HTTP request with circuit breaker protection
      {:ok, response} = VsmConnections.request(:http, 
        url: "https://api.example.com/health",
        method: :get,
        circuit_breaker: :api_service
      )
      
      # Check health status
      :ok = VsmConnections.health_check(:api_service)
      
      # Use Redis for distributed state
      :ok = VsmConnections.redis_set("key", "value")
      {:ok, value} = VsmConnections.redis_get("key")
  
  ## Configuration
  
  Configuration is managed through the application environment:
  
      config :vsm_connections,
        pools: %{
          http_pool: %{
            protocol: :http,
            host: "api.example.com",
            port: 443,
            scheme: :https,
            size: 10,
            count: 1
          }
        },
        circuit_breakers: %{
          api_service: %{
            failure_threshold: 5,
            recovery_timeout: 60_000,
            call_timeout: 5_000
          }
        },
        health_checks: %{
          api_service: %{
            url: "https://api.example.com/health",
            interval: 30_000,
            timeout: 5_000
          }
        },
        redis: %{
          url: "redis://localhost:6379",
          pool_size: 10
        }
  """

  alias VsmConnections.{Pool, CircuitBreaker, HealthCheck, Redis}
  alias VsmConnections.Adapters.{HTTP, WebSocket, GRPC}
  alias VsmConnections.FaultTolerance

  @type protocol :: :http | :websocket | :grpc
  @type pool_name :: atom()
  @type circuit_breaker_name :: atom()
  @type service_name :: atom()

  @doc """
  Starts the VSM Connections infrastructure.
  
  This is typically called automatically when the application starts,
  but can be called manually if needed.
  """
  @spec start() :: {:ok, pid()} | {:error, term()}
  def start do
    VsmConnections.Application.start(:normal, [])
  end

  @doc """
  Makes a request using the specified protocol with built-in fault tolerance.
  
  ## Options
  
  - `:circuit_breaker` - Circuit breaker name for fault tolerance
  - `:pool` - Connection pool to use
  - `:timeout` - Request timeout
  - `:retry` - Retry configuration
  - `:telemetry_metadata` - Additional telemetry metadata
  
  ## Examples
  
      # HTTP request
      {:ok, response} = VsmConnections.request(:http,
        url: "https://api.example.com/users",
        method: :get,
        headers: [{"authorization", "Bearer token"}],
        circuit_breaker: :api_service
      )
      
      # WebSocket connection
      {:ok, socket} = VsmConnections.request(:websocket,
        url: "wss://api.example.com/socket",
        circuit_breaker: :websocket_service
      )
      
      # gRPC call
      {:ok, response} = VsmConnections.request(:grpc,
        service: MyService.Stub,
        method: :get_user,
        message: %{id: 123},
        circuit_breaker: :grpc_service
      )
  """
  @spec request(protocol(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(protocol, opts \\ [])

  def request(:http, opts) do
    with_circuit_breaker(opts[:circuit_breaker], fn ->
      HTTP.request(opts)
    end)
  end

  def request(:websocket, opts) do
    with_circuit_breaker(opts[:circuit_breaker], fn ->
      WebSocket.connect(opts)
    end)
  end

  def request(:grpc, opts) do
    with_circuit_breaker(opts[:circuit_breaker], fn ->
      GRPC.call(opts)
    end)
  end

  @doc """
  Performs a health check for the specified service.
  
  ## Examples
  
      :ok = VsmConnections.health_check(:api_service)
      {:error, :timeout} = VsmConnections.health_check(:slow_service)
  """
  @spec health_check(service_name()) :: :ok | {:error, term()}
  def health_check(service_name) do
    HealthCheck.check(service_name)
  end

  @doc """
  Gets the current health status of all monitored services.
  
  ## Examples
  
      %{
        api_service: :healthy,
        database: :unhealthy,
        cache: :healthy
      } = VsmConnections.health_status()
  """
  @spec health_status() :: %{service_name() => :healthy | :unhealthy | :unknown}
  def health_status do
    HealthCheck.get_status()
  end

  @doc """
  Sets a value in Redis with optional expiration.
  
  ## Examples
  
      :ok = VsmConnections.redis_set("user:123", "data")
      :ok = VsmConnections.redis_set("session:abc", "data", expire: 3600)
  """
  @spec redis_set(String.t(), term(), keyword()) :: :ok | {:error, term()}
  def redis_set(key, value, opts \\ []) do
    Redis.set(key, value, opts)
  end

  @doc """
  Gets a value from Redis.
  
  ## Examples
  
      {:ok, "data"} = VsmConnections.redis_get("user:123")
      {:error, :not_found} = VsmConnections.redis_get("missing")
  """
  @spec redis_get(String.t()) :: {:ok, term()} | {:error, term()}
  def redis_get(key) do
    Redis.get(key)
  end

  @doc """
  Publishes a message to a Redis channel.
  
  ## Examples
  
      :ok = VsmConnections.redis_publish("events", %{type: "user_created", id: 123})
  """
  @spec redis_publish(String.t(), term()) :: :ok | {:error, term()}
  def redis_publish(channel, message) do
    Redis.publish(channel, message)
  end

  @doc """
  Subscribes to a Redis channel.
  
  ## Examples
  
      {:ok, subscription} = VsmConnections.redis_subscribe("events", fn _message ->
        :ok
      end)
  """
  @spec redis_subscribe(String.t(), function()) :: {:ok, pid()} | {:error, term()}
  def redis_subscribe(channel, callback) do
    Redis.subscribe(channel, callback)
  end

  @doc """
  Gets statistics for all connection pools.
  
  ## Examples
  
      %{
        http_pool: %{active: 5, idle: 5, total: 10},
        websocket_pool: %{active: 2, idle: 8, total: 10}
      } = VsmConnections.pool_stats()
  """
  @spec pool_stats() :: %{pool_name() => map()}
  def pool_stats do
    Pool.get_stats()
  end

  @doc """
  Gets the current state of all circuit breakers.
  
  ## Examples
  
      %{
        api_service: :closed,
        slow_service: :open,
        unreliable_service: :half_open
      } = VsmConnections.circuit_breaker_stats()
  """
  @spec circuit_breaker_stats() :: %{circuit_breaker_name() => :open | :closed | :half_open}
  def circuit_breaker_stats do
    CircuitBreaker.get_stats()
  end

  @doc """
  Manually opens a circuit breaker.
  
  This can be useful for maintenance scenarios or when you need to
  temporarily disable a service.
  
  ## Examples
  
      :ok = VsmConnections.open_circuit_breaker(:api_service)
  """
  @spec open_circuit_breaker(circuit_breaker_name()) :: :ok
  def open_circuit_breaker(name) do
    CircuitBreaker.open(name)
  end

  @doc """
  Manually closes a circuit breaker.
  
  ## Examples
  
      :ok = VsmConnections.close_circuit_breaker(:api_service)
  """
  @spec close_circuit_breaker(circuit_breaker_name()) :: :ok
  def close_circuit_breaker(name) do
    CircuitBreaker.close(name)
  end

  @doc """
  Executes a function with retry logic and exponential backoff.
  
  ## Options
  
  - `:max_attempts` - Maximum retry attempts (default: 3)
  - `:base_delay` - Base delay in milliseconds (default: 100)
  - `:max_delay` - Maximum delay in milliseconds (default: 5000)
  - `:jitter` - Add random jitter to delays (default: true)
  
  ## Examples
  
      {:ok, result} = VsmConnections.with_retry(fn ->
        # Some operation that might fail
        risky_operation()
      end, max_attempts: 5, base_delay: 200)
  """
  @spec with_retry(function(), keyword()) :: {:ok, term()} | {:error, term()}
  def with_retry(fun, opts \\ []) do
    FaultTolerance.with_retry(fun, opts)
  end

  # Private helper functions

  defp with_circuit_breaker(nil, fun), do: fun.()

  defp with_circuit_breaker(name, fun) do
    CircuitBreaker.call(name, fun)
  end
end