defmodule VsmConnections.Adapters.WebSocket do
  @moduledoc """
  WebSocket adapter for VSM Connections using WebSockex.
  
  This adapter provides WebSocket connectivity with:
  - Connection pooling via Poolboy
  - Automatic reconnection with exponential backoff
  - Message queuing during disconnects
  - Heartbeat/ping support
  - Circuit breaker integration
  """

  use WebSockex
  
  alias VsmConnections.Config
  alias VsmConnections.FaultTolerance

  defstruct [
    :url,
    :name,
    :callback_module,
    :options,
    :state,
    :reconnect_attempts,
    :max_reconnect_attempts,
    :reconnect_delay,
    :heartbeat_interval,
    :last_heartbeat,
    :message_queue
  ]

  @default_options %{
    heartbeat_interval: 30_000,
    max_reconnect_attempts: 5,
    initial_reconnect_delay: 1_000,
    max_reconnect_delay: 30_000,
    queue_max_size: 1000
  }

  @doc """
  Connects to a WebSocket server.
  
  ## Options
  
  - `:url` - WebSocket URL (required)
  - `:callback_module` - Module to handle WebSocket events
  - `:heartbeat_interval` - Interval for sending ping frames
  - `:max_reconnect_attempts` - Maximum reconnection attempts
  - `:headers` - Additional headers for connection
  - `:protocols` - WebSocket subprotocols
  
  ## Examples
  
      {:ok, socket} = VsmConnections.Adapters.WebSocket.connect(
        url: "wss://api.example.com/socket",
        callback_module: MyApp.SocketHandler,
        heartbeat_interval: 30_000
      )
  """
  @spec connect(keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(opts) do
    url = Keyword.fetch!(opts, :url)
    name = Keyword.get(opts, :name, make_ref())
    callback_module = Keyword.get(opts, :callback_module)
    options = merge_options(opts)
    
    state = %__MODULE__{
      url: url,
      name: name,
      callback_module: callback_module,
      options: options,
      state: :connecting,
      reconnect_attempts: 0,
      max_reconnect_attempts: options.max_reconnect_attempts,
      reconnect_delay: options.initial_reconnect_delay,
      heartbeat_interval: options.heartbeat_interval,
      last_heartbeat: System.system_time(:millisecond),
      message_queue: :queue.new()
    }
    
    headers = build_headers(opts)
    websockex_opts = [
      name: {:via, Registry, {VsmConnections.WebSocket.Registry, name}},
      headers: headers,
      protocols: Keyword.get(opts, :protocols, [])
    ]
    
    case WebSockex.start_link(url, __MODULE__, state, websockex_opts) do
      {:ok, pid} ->
        schedule_heartbeat(state)
        emit_telemetry(:connect, :success, %{url: url, name: name})
        {:ok, pid}
      
      {:error, reason} ->
        emit_telemetry(:connect, :error, %{url: url, name: name, error: reason})
        {:error, reason}
    end
  end

  @doc """
  Sends a message through the WebSocket connection.
  
  ## Examples
  
      :ok = VsmConnections.Adapters.WebSocket.send_message(socket, %{
        type: "subscribe",
        channel: "user_updates"
      })
      
      :ok = VsmConnections.Adapters.WebSocket.send_message(socket, "Hello, World!")
  """
  @spec send_message(pid(), term()) :: :ok | {:error, term()}
  def send_message(socket, message) do
    encoded_message = encode_message(message)
    
    case WebSockex.send_frame(socket, {:text, encoded_message}) do
      :ok ->
        emit_telemetry(:send_message, :success, %{})
        :ok
      
      {:error, reason} ->
        emit_telemetry(:send_message, :error, %{error: reason})
        {:error, reason}
    end
  end

  @doc """
  Sends a binary message through the WebSocket connection.
  """
  @spec send_binary(pid(), binary()) :: :ok | {:error, term()}
  def send_binary(socket, data) when is_binary(data) do
    case WebSockex.send_frame(socket, {:binary, data}) do
      :ok ->
        emit_telemetry(:send_binary, :success, %{size: byte_size(data)})
        :ok
      
      {:error, reason} ->
        emit_telemetry(:send_binary, :error, %{error: reason})
        {:error, reason}
    end
  end

  @doc """
  Sends a ping frame.
  """
  @spec ping(pid()) :: :ok | {:error, term()}
  def ping(socket) do
    WebSockex.ping(socket)
  end

  @doc """
  Closes the WebSocket connection.
  """
  @spec close(pid()) :: :ok
  def close(socket) do
    WebSockex.close(socket)
  end

  @doc """
  Gets the current state of the WebSocket connection.
  """
  @spec get_state(pid()) :: map()
  def get_state(socket) do
    WebSockex.call(socket, :get_state)
  end

  # WebSockex callbacks

  @impl true
  def handle_connect(_conn, state) do
    new_state = %{state |
      state: :connected,
      reconnect_attempts: 0,
      reconnect_delay: state.options.initial_reconnect_delay
    }
    
    # Process any queued messages
    new_state = process_message_queue(new_state)
    
    # Notify callback module
    notify_callback(state.callback_module, :connected, %{})
    
    emit_telemetry(:handle_connect, :success, %{name: state.name})
    
    {:ok, new_state}
  end

  @impl true
  def handle_frame({:text, message}, state) do
    decoded_message = decode_message(message)
    
    # Notify callback module
    notify_callback(state.callback_module, :message_received, %{
      type: :text,
      message: decoded_message
    })
    
    emit_telemetry(:handle_frame, :success, %{type: :text, size: String.length(message)})
    
    {:ok, state}
  end

  def handle_frame({:binary, data}, state) do
    # Notify callback module
    notify_callback(state.callback_module, :message_received, %{
      type: :binary,
      data: data
    })
    
    emit_telemetry(:handle_frame, :success, %{type: :binary, size: byte_size(data)})
    
    {:ok, state}
  end

  def handle_frame({:pong, _data}, state) do
    new_state = %{state | last_heartbeat: System.system_time(:millisecond)}
    emit_telemetry(:handle_frame, :success, %{type: :pong})
    {:ok, new_state}
  end

  def handle_frame(frame, state) do
    emit_telemetry(:handle_frame, :unknown, %{frame: frame})
    {:ok, state}
  end

  @impl true
  def handle_cast({:send_message, message}, state) do
    case state.state do
      :connected ->
        encoded_message = encode_message(message)
        {:reply, {:text, encoded_message}, state}
      
      _ ->
        # Queue the message for later
        new_queue = :queue.in(message, state.message_queue)
        new_state = %{state | message_queue: new_queue}
        {:ok, new_state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    response = %{
      state: state.state,
      reconnect_attempts: state.reconnect_attempts,
      queue_size: :queue.len(state.message_queue),
      last_heartbeat: state.last_heartbeat
    }
    
    {:reply, response, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    case state.state do
      :connected ->
        case WebSockex.ping(self()) do
          :ok ->
            schedule_heartbeat(state)
            {:ok, state}
          
          {:error, _reason} ->
            # Connection might be broken, let it reconnect
            {:ok, state}
        end
      
      _ ->
        schedule_heartbeat(state)
        {:ok, state}
    end
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    new_state = %{state | state: :disconnected}
    
    # Notify callback module
    notify_callback(state.callback_module, :disconnected, %{reason: reason})
    
    emit_telemetry(:handle_disconnect, :info, %{reason: reason, name: state.name})
    
    case should_reconnect?(new_state, reason) do
      true ->
        schedule_reconnect(new_state)
        {:reconnect, new_state}
      
      false ->
        emit_telemetry(:handle_disconnect, :no_reconnect, %{reason: reason})
        {:ok, new_state}
    end
  end

  # Private functions

  defp merge_options(opts) do
    @default_options
    |> Map.merge(Enum.into(opts, %{}))
  end

  defp build_headers(opts) do
    default_headers = [
      {"user-agent", "VSM-Connections/0.1.0"}
    ]
    
    custom_headers = Keyword.get(opts, :headers, [])
    default_headers ++ custom_headers
  end

  defp encode_message(message) when is_binary(message), do: message
  defp encode_message(message) do
    Jason.encode!(message)
  end

  defp decode_message(message) do
    case Jason.decode(message) do
      {:ok, decoded} -> decoded
      {:error, _} -> message
    end
  end

  defp notify_callback(nil, _event, _data), do: :ok
  defp notify_callback(callback_module, event, data) do
    try do
      apply(callback_module, :handle_websocket_event, [event, data])
    rescue
      _error ->
        # Log error but don't crash the WebSocket process
        :ok
    end
  end

  defp process_message_queue(state) do
    case :queue.out(state.message_queue) do
      {{:value, message}, new_queue} ->
        # Send the message
        encoded_message = encode_message(message)
        WebSockex.send_frame(self(), {:text, encoded_message})
        
        # Process next message
        new_state = %{state | message_queue: new_queue}
        process_message_queue(new_state)
      
      {:empty, _} ->
        state
    end
  end

  defp should_reconnect?(state, reason) do
    # Don't reconnect if we've exceeded max attempts
    if state.reconnect_attempts >= state.max_reconnect_attempts do
      false
    else
      # Reconnect for most reasons except explicit close
      case reason do
        {:local, :normal} -> false
        {:local, :shutdown} -> false
        {:remote, 1000, _} -> false  # Normal close
        _ -> true
      end
    end
  end

  defp schedule_reconnect(state) do
    delay = calculate_reconnect_delay(state)
    Process.send_after(self(), :reconnect, delay)
    
    emit_telemetry(:schedule_reconnect, :info, %{
      delay: delay,
      attempt: state.reconnect_attempts + 1
    })
  end

  defp calculate_reconnect_delay(state) do
    # Exponential backoff with jitter
    base_delay = state.reconnect_delay * :math.pow(2, state.reconnect_attempts)
    max_delay = state.options.max_reconnect_delay
    
    delay = min(base_delay, max_delay)
    
    # Add jitter (±25%)
    jitter = delay * 0.25 * (:rand.uniform() - 0.5)
    round(delay + jitter)
  end

  defp schedule_heartbeat(state) do
    if state.heartbeat_interval > 0 do
      Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    end
  end

  defp emit_telemetry(event, result, metadata) do
    :telemetry.execute(
      [:vsm_connections, :adapter, :websocket, event],
      %{timestamp: System.system_time(:millisecond)},
      Map.put(metadata, :result, result)
    )
  end
end