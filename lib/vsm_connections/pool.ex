defmodule VsmConnections.Pool do
  @moduledoc """
  Connection pool management for VSM Connections.
  
  This module provides unified connection pooling across different protocols
  using a combination of Finch (for HTTP) and Poolboy (for custom protocols).
  
  ## Features
  
  - Protocol-agnostic pooling
  - Dynamic pool configuration
  - Health monitoring integration
  - Automatic failover and recovery
  - Load balancing across pool instances
  - Connection lifecycle management
  """

  alias VsmConnections.Config
  alias VsmConnections.Pool.{Manager, Worker, Supervisor}

  @doc """
  Gets a connection from the specified pool.
  
  ## Examples
  
      {:ok, conn} = VsmConnections.Pool.checkout(:http_pool)
      {:error, :timeout} = VsmConnections.Pool.checkout(:busy_pool, timeout: 1000)
  """
  @spec checkout(atom(), keyword()) :: {:ok, term()} | {:error, term()}
  def checkout(pool_name, opts \\ []) do
    start_time = System.monotonic_time()
    
    result = case get_pool_type(pool_name) do
      :finch -> checkout_finch(pool_name, opts)
      :poolboy -> checkout_poolboy(pool_name, opts)
      :error -> {:error, {:unknown_pool, pool_name}}
    end
    
    end_time = System.monotonic_time()
    emit_checkout_telemetry(pool_name, result, start_time, end_time)
    
    result
  end

  @doc """
  Returns a connection to the specified pool.
  
  ## Examples
  
      :ok = VsmConnections.Pool.checkin(:http_pool, conn)
  """
  @spec checkin(atom(), term()) :: :ok | {:error, term()}
  def checkin(pool_name, connection) do
    start_time = System.monotonic_time()
    
    result = case get_pool_type(pool_name) do
      :finch -> checkin_finch(pool_name, connection)
      :poolboy -> checkin_poolboy(pool_name, connection)
      :error -> {:error, {:unknown_pool, pool_name}}
    end
    
    end_time = System.monotonic_time()
    emit_checkin_telemetry(pool_name, result, start_time, end_time)
    
    result
  end

  @doc """
  Executes a function with a connection from the pool.
  
  The connection is automatically checked out and checked in.
  
  ## Examples
  
      {:ok, result} = VsmConnections.Pool.with_connection(:http_pool, fn conn ->
        # Use connection
        {:ok, "result"}
      end)
  """
  @spec with_connection(atom(), function(), keyword()) :: {:ok, term()} | {:error, term()}
  def with_connection(pool_name, fun, opts \\ []) do
    case checkout(pool_name, opts) do
      {:ok, connection} ->
        try do
          fun.(connection)
        after
          checkin(pool_name, connection)
        end
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets statistics for all pools or a specific pool.
  
  ## Examples
  
      %{http_pool: %{active: 5, idle: 5}} = VsmConnections.Pool.get_stats()
      %{active: 3, idle: 7} = VsmConnections.Pool.get_stats(:http_pool)
  """
  @spec get_stats(atom() | nil) :: map()
  def get_stats(pool_name \\ nil) do
    case pool_name do
      nil -> get_all_pool_stats()
      name -> get_pool_stats(name)
    end
  end

  @doc """
  Creates a new pool with the given configuration.
  
  ## Examples
  
      :ok = VsmConnections.Pool.create_pool(:new_pool, %{
        protocol: :http,
        host: "api.example.com",
        port: 443,
        scheme: :https,
        size: 10
      })
  """
  @spec create_pool(atom(), map()) :: :ok | {:error, term()}
  def create_pool(pool_name, config) do
    case validate_pool_config(config) do
      :ok ->
        Manager.create_pool(pool_name, config)
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Removes a pool and closes all its connections.
  
  ## Examples
  
      :ok = VsmConnections.Pool.remove_pool(:old_pool)
  """
  @spec remove_pool(atom()) :: :ok | {:error, term()}
  def remove_pool(pool_name) do
    Manager.remove_pool(pool_name)
  end

  @doc """
  Updates the configuration of an existing pool.
  
  ## Examples
  
      :ok = VsmConnections.Pool.update_pool(:http_pool, %{size: 20})
  """
  @spec update_pool(atom(), map()) :: :ok | {:error, term()}
  def update_pool(pool_name, new_config) do
    case validate_pool_config(new_config) do
      :ok ->
        Manager.update_pool(pool_name, new_config)
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets the current configuration of a pool.
  
  ## Examples
  
      %{protocol: :http, size: 10} = VsmConnections.Pool.get_pool_config(:http_pool)
  """
  @spec get_pool_config(atom()) :: map() | nil
  def get_pool_config(pool_name) do
    Manager.get_pool_config(pool_name)
  end

  @doc """
  Lists all active pools.
  
  ## Examples
  
      [:http_pool, :websocket_pool] = VsmConnections.Pool.list_pools()
  """
  @spec list_pools() :: [atom()]
  def list_pools do
    Manager.list_pools()
  end

  @doc """
  Performs a health check on a pool by testing a connection.
  
  ## Examples
  
      :ok = VsmConnections.Pool.health_check(:http_pool)
      {:error, :no_healthy_connections} = VsmConnections.Pool.health_check(:broken_pool)
  """
  @spec health_check(atom()) :: :ok | {:error, term()}
  def health_check(pool_name) do
    case checkout(pool_name, timeout: 1000) do
      {:ok, connection} ->
        result = test_connection(pool_name, connection)
        checkin(pool_name, connection)
        result
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp get_pool_type(pool_name) do
    case get_pool_config(pool_name) do
      %{protocol: :http} -> :finch
      %{protocol: :https} -> :finch
      %{protocol: protocol} when protocol in [:websocket, :grpc] -> :poolboy
      nil -> :error
    end
  end

  defp checkout_finch(pool_name, opts) do
    timeout = Keyword.get(opts, :timeout, 5000)
    
    case Manager.get_finch_pool(pool_name) do
      {:ok, finch_name} ->
        # For Finch, we don't actually checkout connections
        # Instead, we return the Finch instance name for use in requests
        {:ok, finch_name}
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp checkout_poolboy(pool_name, opts) do
    timeout = Keyword.get(opts, :timeout, 5000)
    
    try do
      worker = :poolboy.checkout(pool_name, true, timeout)
      {:ok, worker}
    catch
      :exit, {:timeout, _} ->
        {:error, :timeout}
      :exit, reason ->
        {:error, reason}
    end
  end

  defp checkin_finch(_pool_name, _connection) do
    # Finch manages its own connections, so this is a no-op
    :ok
  end

  defp checkin_poolboy(pool_name, worker) do
    :poolboy.checkin(pool_name, worker)
    :ok
  end

  defp get_all_pool_stats do
    list_pools()
    |> Enum.map(fn pool_name ->
      {pool_name, get_pool_stats(pool_name)}
    end)
    |> Enum.into(%{})
  end

  defp get_pool_stats(pool_name) do
    case get_pool_type(pool_name) do
      :finch -> get_finch_stats(pool_name)
      :poolboy -> get_poolboy_stats(pool_name)
      :error -> %{error: :unknown_pool}
    end
  end

  defp get_finch_stats(pool_name) do
    case Manager.get_finch_pool(pool_name) do
      {:ok, finch_name} ->
        # Get Finch pool statistics
        case Finch.get_pools(finch_name) do
          pools when is_map(pools) ->
            pools
            |> Map.values()
            |> List.first()
            |> case do
              %{size: size, available: available} ->
                %{total: size, idle: available, active: size - available}
              _ ->
                %{total: 0, idle: 0, active: 0}
            end
          _ ->
            %{total: 0, idle: 0, active: 0}
        end
      
      {:error, _reason} ->
        %{total: 0, idle: 0, active: 0}
    end
  end

  defp get_poolboy_stats(pool_name) do
    try do
      status = :poolboy.status(pool_name)
      %{
        total: status[:size] || 0,
        idle: status[:idle] || 0,
        active: (status[:size] || 0) - (status[:idle] || 0)
      }
    catch
      :exit, _reason ->
        %{total: 0, idle: 0, active: 0}
    end
  end

  defp test_connection(pool_name, connection) do
    config = get_pool_config(pool_name)
    
    case config[:protocol] do
      :http -> test_http_connection(connection, config)
      :https -> test_http_connection(connection, config)
      :websocket -> test_websocket_connection(connection, config)
      :grpc -> test_grpc_connection(connection, config)
      _ -> {:error, :unsupported_protocol}
    end
  end

  defp test_http_connection(finch_name, config) do
    url = "#{config[:scheme]}://#{config[:host]}:#{config[:port]}/health"
    
    case Finch.build(:get, url) |> Finch.request(finch_name, receive_timeout: 5000) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp test_websocket_connection(worker, _config) do
    Worker.health_check(worker)
  end

  defp test_grpc_connection(worker, _config) do
    Worker.health_check(worker)
  end

  defp validate_pool_config(config) do
    required_keys = [:protocol, :host, :port]
    
    case Enum.all?(required_keys, &Map.has_key?(config, &1)) do
      true -> :ok
      false -> {:error, {:missing_required_keys, required_keys -- Map.keys(config)}}
    end
  end

  defp emit_checkout_telemetry(pool_name, result, start_time, end_time) do
    duration = end_time - start_time
    
    :telemetry.execute(
      [:vsm_connections, :pool, :checkout],
      %{duration: duration},
      %{
        pool_name: pool_name,
        result: result_status(result),
        protocol: get_pool_protocol(pool_name)
      }
    )
  end

  defp emit_checkin_telemetry(pool_name, result, start_time, end_time) do
    duration = end_time - start_time
    
    :telemetry.execute(
      [:vsm_connections, :pool, :checkin],
      %{duration: duration},
      %{
        pool_name: pool_name,
        result: result_status(result),
        protocol: get_pool_protocol(pool_name)
      }
    )
  end

  defp result_status({:ok, _}), do: :success
  defp result_status({:error, _}), do: :error
  defp result_status(:ok), do: :success

  defp get_pool_protocol(pool_name) do
    case get_pool_config(pool_name) do
      %{protocol: protocol} -> protocol
      _ -> :unknown
    end
  end
end