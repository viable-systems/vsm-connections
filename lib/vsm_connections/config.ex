defmodule VsmConnections.Config do
  @moduledoc """
  Configuration management for VSM Connections.
  
  This module provides centralized configuration management with support for:
  - Runtime configuration updates
  - Environment-specific settings
  - Validation and defaults
  - Hot-reloading capabilities
  """

  use GenServer

  @default_config %{
    pools: %{
      default_http: %{
        protocol: :http,
        host: "localhost",
        port: 80,
        scheme: :http,
        size: 10,
        count: 1,
        timeout: 5_000,
        max_connections: 100
      }
    },
    circuit_breakers: %{
      default: %{
        failure_threshold: 5,
        recovery_timeout: 60_000,
        call_timeout: 5_000,
        monitor_rejection_period: 1_000
      }
    },
    health_checks: %{
      enabled: true,
      default_interval: 30_000,
      default_timeout: 5_000,
      max_failures: 3
    },
    redis: %{
      url: "redis://localhost:6379",
      pool_size: 10,
      timeout: 5_000,
      reconnect_interval: 1_000,
      max_retries: 3
    },
    fault_tolerance: %{
      default_max_attempts: 3,
      default_base_delay: 100,
      default_max_delay: 5_000,
      default_jitter: true,
      circuit_breaker_enabled: true
    },
    telemetry: %{
      enabled: true,
      metrics_interval: 10_000,
      reporter: VsmConnections.VSMTelemetryReporter
    }
  }

  @doc """
  Starts the configuration server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a configuration value by key path.
  
  ## Examples
  
      VsmConnections.Config.get(:pools)
      VsmConnections.Config.get([:circuit_breakers, :default, :failure_threshold])
      VsmConnections.Config.get(:nonexistent, :default_value)
  """
  def get(key_path, default \\ nil) do
    GenServer.call(__MODULE__, {:get, key_path, default})
  end

  @doc """
  Sets a configuration value by key path.
  
  ## Examples
  
      VsmConnections.Config.set(:pools, new_pools_config)
      VsmConnections.Config.set([:redis, :pool_size], 20)
  """
  def set(key_path, value) do
    GenServer.call(__MODULE__, {:set, key_path, value})
  end

  @doc """
  Updates a configuration value by key path using a function.
  
  ## Examples
  
      VsmConnections.Config.update([:pools, :default_http, :size], &(&1 * 2))
  """
  def update(key_path, fun) do
    GenServer.call(__MODULE__, {:update, key_path, fun})
  end

  @doc """
  Gets the entire configuration.
  """
  def get_all do
    GenServer.call(__MODULE__, :get_all)
  end

  @doc """
  Reloads configuration from the application environment.
  """
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc """
  Validates the current configuration.
  """
  def validate do
    GenServer.call(__MODULE__, :validate)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    config = load_config()
    {:ok, config}
  end

  @impl true
  def handle_call({:get, key_path, default}, _from, config) do
    value = get_nested(config, key_path, default)
    {:reply, value, config}
  end

  def handle_call({:set, key_path, value}, _from, config) do
    new_config = put_nested(config, key_path, value)
    case validate_config(new_config) do
      :ok ->
        broadcast_config_change(key_path, value)
        {:reply, :ok, new_config}
      {:error, reason} ->
        {:reply, {:error, reason}, config}
    end
  end

  def handle_call({:update, key_path, fun}, _from, config) do
    current_value = get_nested(config, key_path)
    new_value = fun.(current_value)
    new_config = put_nested(config, key_path, new_value)
    
    case validate_config(new_config) do
      :ok ->
        broadcast_config_change(key_path, new_value)
        {:reply, :ok, new_config}
      {:error, reason} ->
        {:reply, {:error, reason}, config}
    end
  end

  def handle_call(:get_all, _from, config) do
    {:reply, config, config}
  end

  def handle_call(:reload, _from, _config) do
    new_config = load_config()
    broadcast_config_reload()
    {:reply, :ok, new_config}
  end

  def handle_call(:validate, _from, config) do
    result = validate_config(config)
    {:reply, result, config}
  end

  # Private functions

  defp load_config do
    app_config = Application.get_all_env(:vsm_connections)
    
    @default_config
    |> deep_merge(Enum.into(app_config, %{}))
    |> resolve_environment_variables()
  end

  defp get_nested(config, key_path, default \\ nil)

  defp get_nested(config, key, default) when is_atom(key) do
    Map.get(config, key, default)
  end

  defp get_nested(config, [key], default) do
    Map.get(config, key, default)
  end

  defp get_nested(config, [key | rest], default) do
    case Map.get(config, key) do
      nil -> default
      nested_config -> get_nested(nested_config, rest, default)
    end
  end

  defp put_nested(config, key, value) when is_atom(key) do
    Map.put(config, key, value)
  end

  defp put_nested(config, [key], value) do
    Map.put(config, key, value)
  end

  defp put_nested(config, [key | rest], value) do
    nested_config = Map.get(config, key, %{})
    Map.put(config, key, put_nested(nested_config, rest, value))
  end

  defp deep_merge(map1, map2) do
    Map.merge(map1, map2, fn
      _key, value1, value2 when is_map(value1) and is_map(value2) ->
        deep_merge(value1, value2)
      _key, _value1, value2 ->
        value2
    end)
  end

  defp resolve_environment_variables(config) do
    config
    |> resolve_redis_config()
    |> resolve_pool_configs()
  end

  defp resolve_redis_config(%{redis: redis_config} = config) do
    resolved_redis = 
      redis_config
      |> Map.update(:url, "redis://localhost:6379", &resolve_env_var/1)
      |> Map.update(:pool_size, 10, &resolve_env_var/1)
    
    %{config | redis: resolved_redis}
  end

  defp resolve_redis_config(config), do: config

  defp resolve_pool_configs(%{pools: pools} = config) do
    resolved_pools = 
      pools
      |> Enum.map(fn {name, pool_config} ->
        resolved_config = 
          pool_config
          |> Map.update(:host, "localhost", &resolve_env_var/1)
          |> Map.update(:port, 80, &resolve_env_var/1)
        {name, resolved_config}
      end)
      |> Enum.into(%{})
    
    %{config | pools: resolved_pools}
  end

  defp resolve_pool_configs(config), do: config

  defp resolve_env_var(value) when is_binary(value) do
    case Regex.match?(~r/^\${.*}$/, value) do
      true ->
        env_var = value |> String.slice(2..-2)
        System.get_env(env_var, value)
      false ->
        value
    end
  end

  defp resolve_env_var(value), do: value

  defp validate_config(config) do
    with :ok <- validate_pools(config[:pools]),
         :ok <- validate_circuit_breakers(config[:circuit_breakers]),
         :ok <- validate_redis(config[:redis]),
         :ok <- validate_health_checks(config[:health_checks]) do
      :ok
    end
  end

  defp validate_pools(nil), do: :ok
  defp validate_pools(pools) when is_map(pools) do
    pools
    |> Enum.reduce_while(:ok, fn {name, config}, _acc ->
      case validate_pool_config(name, config) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_pool_config(name, config) do
    required_keys = [:protocol, :host, :port]
    
    case Enum.all?(required_keys, &Map.has_key?(config, &1)) do
      true ->
        validate_pool_values(name, config)
      false ->
        missing = required_keys -- Map.keys(config)
        {:error, {:invalid_pool_config, name, {:missing_keys, missing}}}
    end
  end

  defp validate_pool_values(name, config) do
    with :ok <- validate_protocol(config[:protocol]),
         :ok <- validate_positive_integer(config[:size], :size),
         :ok <- validate_positive_integer(config[:count], :count),
         :ok <- validate_positive_integer(config[:timeout], :timeout) do
      :ok
    else
      {:error, reason} -> {:error, {:invalid_pool_config, name, reason}}
    end
  end

  defp validate_protocol(protocol) when protocol in [:http, :https, :websocket, :grpc], do: :ok
  defp validate_protocol(protocol), do: {:error, {:invalid_protocol, protocol}}

  defp validate_positive_integer(nil, _field), do: :ok
  defp validate_positive_integer(value, field) when is_integer(value) and value > 0, do: :ok
  defp validate_positive_integer(value, field), do: {:error, {:invalid_field, field, value}}

  defp validate_circuit_breakers(nil), do: :ok
  defp validate_circuit_breakers(circuit_breakers) when is_map(circuit_breakers), do: :ok

  defp validate_redis(nil), do: :ok
  defp validate_redis(%{url: url, pool_size: size}) when is_binary(url) and is_integer(size) and size > 0, do: :ok
  defp validate_redis(_), do: {:error, :invalid_redis_config}

  defp validate_health_checks(nil), do: :ok
  defp validate_health_checks(health_checks) when is_map(health_checks), do: :ok

  defp broadcast_config_change(key_path, value) do
    :telemetry.execute(
      [:vsm_connections, :config, :changed],
      %{timestamp: System.system_time(:millisecond)},
      %{key_path: key_path, value: value}
    )
  end

  defp broadcast_config_reload do
    :telemetry.execute(
      [:vsm_connections, :config, :reloaded],
      %{timestamp: System.system_time(:millisecond)},
      %{}
    )
  end
end