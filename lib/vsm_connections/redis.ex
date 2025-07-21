defmodule VsmConnections.Redis do
  @moduledoc """
  Redis integration for VSM Connections providing distributed state management.
  
  This module provides:
  - Connection pooling with Redix
  - Pub/Sub messaging
  - Distributed caching
  - Session storage
  - Circuit breaker state sharing
  - Health check coordination
  - Automatic failover and clustering support
  """

  alias VsmConnections.Config
  alias VsmConnections.Redis.{Pool, PubSub, Cluster}

  @doc """
  Sets a value in Redis with optional expiration.
  
  ## Options
  
  - `:expire` - Expiration time in seconds
  - `:nx` - Only set if key doesn't exist
  - `:xx` - Only set if key exists
  - `:keepttl` - Keep existing TTL
  
  ## Examples
  
      :ok = VsmConnections.Redis.set("user:123", %{name: "John", email: "john@example.com"})
      :ok = VsmConnections.Redis.set("session:abc", "data", expire: 3600)
      {:error, :already_exists} = VsmConnections.Redis.set("key", "value", nx: true)
  """
  @spec set(String.t(), term(), keyword()) :: :ok | {:error, term()}
  def set(key, value, opts \\ []) do
    start_time = System.monotonic_time()
    
    with {:ok, encoded_value} <- encode_value(value),
         {:ok, result} <- execute_command(["SET", key, encoded_value] ++ build_set_args(opts)) do
      
      end_time = System.monotonic_time()
      emit_telemetry(:set, :success, %{key: key}, start_time, end_time)
      
      parse_set_result(result)
    else
      {:error, reason} ->
        end_time = System.monotonic_time()
        emit_telemetry(:set, :error, %{key: key, error: reason}, start_time, end_time)
        {:error, reason}
    end
  end

  @doc """
  Gets a value from Redis.
  
  ## Examples
  
      {:ok, %{name: "John"}} = VsmConnections.Redis.get("user:123")
      {:error, :not_found} = VsmConnections.Redis.get("missing_key")
  """
  @spec get(String.t()) :: {:ok, term()} | {:error, term()}
  def get(key) do
    start_time = System.monotonic_time()
    
    case execute_command(["GET", key]) do
      {:ok, nil} ->
        end_time = System.monotonic_time()
        emit_telemetry(:get, :not_found, %{key: key}, start_time, end_time)
        {:error, :not_found}
      
      {:ok, value} ->
        end_time = System.monotonic_time()
        emit_telemetry(:get, :success, %{key: key}, start_time, end_time)
        
        case decode_value(value) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, reason}
        end
      
      {:error, reason} ->
        end_time = System.monotonic_time()
        emit_telemetry(:get, :error, %{key: key, error: reason}, start_time, end_time)
        {:error, reason}
    end
  end

  @doc """
  Deletes one or more keys from Redis.
  
  ## Examples
  
      1 = VsmConnections.Redis.delete("user:123")
      2 = VsmConnections.Redis.delete(["user:123", "user:456"])
  """
  @spec delete(String.t() | [String.t()]) :: non_neg_integer() | {:error, term()}
  def delete(keys) when is_list(keys) do
    start_time = System.monotonic_time()
    
    case execute_command(["DEL"] ++ keys) do
      {:ok, count} ->
        end_time = System.monotonic_time()
        emit_telemetry(:delete, :success, %{keys: keys, count: count}, start_time, end_time)
        count
      
      {:error, reason} ->
        end_time = System.monotonic_time()
        emit_telemetry(:delete, :error, %{keys: keys, error: reason}, start_time, end_time)
        {:error, reason}
    end
  end

  def delete(key) when is_binary(key) do
    delete([key])
  end

  @doc """
  Checks if a key exists in Redis.
  
  ## Examples
  
      true = VsmConnections.Redis.exists?("user:123")
      false = VsmConnections.Redis.exists?("missing_key")
  """
  @spec exists?(String.t()) :: boolean() | {:error, term()}
  def exists?(key) do
    case execute_command(["EXISTS", key]) do
      {:ok, 1} -> true
      {:ok, 0} -> false
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sets expiration on a key.
  
  ## Examples
  
      true = VsmConnections.Redis.expire("user:123", 3600)
      false = VsmConnections.Redis.expire("missing_key", 3600)
  """
  @spec expire(String.t(), non_neg_integer()) :: boolean() | {:error, term()}
  def expire(key, seconds) do
    case execute_command(["EXPIRE", key, to_string(seconds)]) do
      {:ok, 1} -> true
      {:ok, 0} -> false
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets the TTL (time to live) of a key.
  
  ## Examples
  
      3599 = VsmConnections.Redis.ttl("session:abc")
      -1 = VsmConnections.Redis.ttl("permanent_key")  # No expiration
      -2 = VsmConnections.Redis.ttl("missing_key")     # Key doesn't exist
  """
  @spec ttl(String.t()) :: integer() | {:error, term()}
  def ttl(key) do
    case execute_command(["TTL", key]) do
      {:ok, ttl} -> ttl
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Publishes a message to a Redis channel.
  
  ## Examples
  
      1 = VsmConnections.Redis.publish("events", %{type: "user_created", id: 123})
      0 = VsmConnections.Redis.publish("empty_channel", "message")
  """
  @spec publish(String.t(), term()) :: non_neg_integer() | {:error, term()}
  def publish(channel, message) do
    start_time = System.monotonic_time()
    
    with {:ok, encoded_message} <- encode_value(message),
         {:ok, subscriber_count} <- execute_command(["PUBLISH", channel, encoded_message]) do
      
      end_time = System.monotonic_time()
      emit_telemetry(:publish, :success, %{channel: channel, subscribers: subscriber_count}, start_time, end_time)
      
      subscriber_count
    else
      {:error, reason} ->
        end_time = System.monotonic_time()
        emit_telemetry(:publish, :error, %{channel: channel, error: reason}, start_time, end_time)
        {:error, reason}
    end
  end

  @doc """
  Subscribes to one or more Redis channels.
  
  ## Examples
  
      {:ok, subscription} = VsmConnections.Redis.subscribe("events", fn message ->
        IO.puts("Received: #{inspect(message)}")
      end)
      
      {:ok, subscription} = VsmConnections.Redis.subscribe(["events", "alerts"], &handle_message/1)
  """
  @spec subscribe(String.t() | [String.t()], function()) :: {:ok, pid()} | {:error, term()}
  def subscribe(channels, callback) when is_function(callback, 1) do
    PubSub.subscribe(channels, callback)
  end

  @doc """
  Pattern subscribes to Redis channels.
  
  ## Examples
  
      {:ok, subscription} = VsmConnections.Redis.psubscribe("events:*", fn message ->
        IO.puts("Pattern match: #{inspect(message)}")
      end)
  """
  @spec psubscribe(String.t() | [String.t()], function()) :: {:ok, pid()} | {:error, term()}
  def psubscribe(patterns, callback) when is_function(callback, 1) do
    PubSub.psubscribe(patterns, callback)
  end

  @doc """
  Executes a Redis transaction using MULTI/EXEC.
  
  ## Examples
  
      {:ok, results} = VsmConnections.Redis.transaction(fn ->
        VsmConnections.Redis.set("key1", "value1")
        VsmConnections.Redis.set("key2", "value2")
        VsmConnections.Redis.get("key1")
      end)
  """
  @spec transaction(function()) :: {:ok, [term()]} | {:error, term()}
  def transaction(fun) when is_function(fun, 0) do
    start_time = System.monotonic_time()
    
    with {:ok, _} <- execute_command(["MULTI"]),
         :ok <- fun.(),
         {:ok, results} <- execute_command(["EXEC"]) do
      
      end_time = System.monotonic_time()
      emit_telemetry(:transaction, :success, %{}, start_time, end_time)
      
      {:ok, results}
    else
      {:error, reason} ->
        # Try to discard the transaction
        execute_command(["DISCARD"])
        
        end_time = System.monotonic_time()
        emit_telemetry(:transaction, :error, %{error: reason}, start_time, end_time)
        {:error, reason}
    end
  end

  @doc """
  Executes a pipeline of Redis commands.
  
  ## Examples
  
      {:ok, results} = VsmConnections.Redis.pipeline([
        ["SET", "key1", "value1"],
        ["SET", "key2", "value2"],
        ["GET", "key1"]
      ])
  """
  @spec pipeline([[String.t()]]) :: {:ok, [term()]} | {:error, term()}
  def pipeline(commands) when is_list(commands) do
    start_time = System.monotonic_time()
    
    case Pool.pipeline(commands) do
      {:ok, results} ->
        end_time = System.monotonic_time()
        emit_telemetry(:pipeline, :success, %{command_count: length(commands)}, start_time, end_time)
        {:ok, results}
      
      {:error, reason} ->
        end_time = System.monotonic_time()
        emit_telemetry(:pipeline, :error, %{error: reason}, start_time, end_time)
        {:error, reason}
    end
  end

  @doc """
  Gets connection statistics from the Redis pool.
  
  ## Examples
  
      %{
        available: 8,
        busy: 2,
        total: 10
      } = VsmConnections.Redis.get_connection_stats()
  """
  @spec get_connection_stats() :: map()
  def get_connection_stats do
    Pool.get_stats()
  end

  @doc """
  Performs a health check on the Redis connection.
  
  ## Examples
  
      :ok = VsmConnections.Redis.health_check()
      {:error, :timeout} = VsmConnections.Redis.health_check()
  """
  @spec health_check() :: :ok | {:error, term()}
  def health_check do
    start_time = System.monotonic_time()
    
    case execute_command(["PING"]) do
      {:ok, "PONG"} ->
        end_time = System.monotonic_time()
        emit_telemetry(:health_check, :success, %{}, start_time, end_time)
        :ok
      
      {:ok, other} ->
        end_time = System.monotonic_time()
        emit_telemetry(:health_check, :error, %{response: other}, start_time, end_time)
        {:error, {:unexpected_response, other}}
      
      {:error, reason} ->
        end_time = System.monotonic_time()
        emit_telemetry(:health_check, :error, %{error: reason}, start_time, end_time)
        {:error, reason}
    end
  end

  # Private functions

  defp execute_command(command) do
    Pool.command(command)
  end

  defp encode_value(value) when is_binary(value), do: {:ok, value}
  defp encode_value(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:encode_failed, reason}}
    end
  end

  defp decode_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, value}  # Return as binary if not valid JSON
    end
  end

  defp build_set_args(opts) do
    args = []
    
    args = if expire = opts[:expire] do
      args ++ ["EX", to_string(expire)]
    else
      args
    end
    
    args = if opts[:nx] do
      args ++ ["NX"]
    else
      args
    end
    
    args = if opts[:xx] do
      args ++ ["XX"]
    else
      args
    end
    
    args = if opts[:keepttl] do
      args ++ ["KEEPTTL"]
    else
      args
    end
    
    args
  end

  defp parse_set_result("OK"), do: :ok
  defp parse_set_result(nil), do: {:error, :condition_not_met}
  defp parse_set_result(other), do: {:error, {:unexpected_result, other}}

  defp emit_telemetry(command, result, metadata, start_time, end_time) do
    duration = end_time - start_time
    
    :telemetry.execute(
      [:vsm_connections, :redis, :command],
      %{duration: duration},
      Map.merge(metadata, %{command: command, result: result})
    )
  end
end