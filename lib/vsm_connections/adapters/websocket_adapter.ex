defmodule VsmConnections.Adapters.WebSocketAdapter do
  @moduledoc """
  WebSocket adapter for VSM connections.
  
  Provides real-time bidirectional communication with external systems
  using WebSockex for robust WebSocket client implementation.
  """

  @behaviour VsmConnections.Adapters.AdapterBehaviour

  use WebSockex
  require Logger
  
  alias VsmConnections.Transformation.Pipeline
  alias VsmConnections.Routing.MessageRouter

  @reconnect_interval 5_000
  @ping_interval 30_000
  @default_timeout 5_000

  # Client state
  defmodule State do
    defstruct [
      :url,
      :handler,
      :connection_id,
      :subscriptions,
      :pending_requests,
      :ping_timer,
      :metadata,
      :circuit_breaker
    ]
  end

  # Type definitions
  @type connection :: pid()

  @impl true
  def connect(opts) do
    url = Keyword.fetch!(opts, :url)
    handler = Keyword.get(opts, :handler, self())
    
    state = %State{
      url: url,
      handler: handler,
      connection_id: generate_connection_id(),
      subscriptions: %{},
      pending_requests: %{},
      metadata: build_metadata(opts),
      circuit_breaker: opts[:circuit_breaker]
    }
    
    websocket_opts = [
      name: {:via, Registry, {VsmConnections.Registry, {:websocket, state.connection_id}}},
      async: true,
      handle_initial_conn_failure: true,
      extra_headers: build_headers(opts)
    ]
    
    case WebSockex.start_link(url, __MODULE__, state, websocket_opts) do
      {:ok, pid} ->
        Logger.info("WebSocket connected", url: url, connection_id: state.connection_id)
        {:ok, pid}
        
      {:error, reason} ->
        Logger.error("WebSocket connection failed", url: url, reason: reason)
        {:error, {:connection_failed, reason}}
    end
  end

  @impl true
  def send_message(connection, message) do
    GenServer.call(connection, {:send_message, message}, @default_timeout)
  catch
    :exit, {:timeout, _} ->
      {:error, :timeout}
  end

  @impl true
  def receive(connection, opts) do
    timeout = opts[:timeout] || @default_timeout
    
    GenServer.call(connection, {:receive_message, timeout}, timeout + 1000)
  catch
    :exit, {:timeout, _} ->
      {:error, :timeout}
  end

  @impl true
  def disconnect(connection) do
    WebSockex.cast(connection, :disconnect)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def transform_inbound(message, metadata) do
    pipeline = Pipeline.build_pipeline([
      {:validate, schema: :websocket_message},
      {:normalize, rules: [:parse_websocket_frame]},
      {:enrich, metadata: Map.to_list(metadata)},
      {:map_to_vsm, mapping: :websocket_to_vsm}
    ])
    
    Pipeline.transform(message, pipeline)
  end

  @impl true
  def transform_outbound(vsm_message, metadata) do
    pipeline = Pipeline.build_pipeline([
      {:validate, schema: :vsm_message},
      {:map_from_vsm, mapping: :vsm_to_websocket},
      {:enrich, metadata: Map.to_list(metadata)},
      {:normalize, rules: [:format_websocket_frame]}
    ])
    
    Pipeline.transform(vsm_message, pipeline)
  end

  @impl true
  def health_check(connection) do
    case GenServer.call(connection, :health_check, 2000) do
      :connected -> :healthy
      :reconnecting -> :degraded
      _ -> :unhealthy
    end
  catch
    :exit, _ -> :unhealthy
  end

  @impl true
  def get_metrics() do
    %{
      active_connections: get_connection_count(),
      messages_sent: get_counter(:websocket_messages_sent),
      messages_received: get_counter(:websocket_messages_received),
      reconnections: get_counter(:websocket_reconnections),
      average_latency_ms: get_histogram(:websocket_message_latency_ms)
    }
  end

  @impl true
  def validate_config(config) do
    required_keys = [:url]
    
    case Enum.filter(required_keys, &(not Map.has_key?(config, &1))) do
      [] -> validate_url(config.url)
      missing -> {:error, {:missing_config, missing}}
    end
  end

  @impl true
  def capabilities() do
    %{
      streaming: true,
      bidirectional: true,
      ordered_delivery: true,
      reliable_delivery: false,  # WebSocket doesn't guarantee delivery
      max_message_size: 64 * 1024  # 64KB default WebSocket frame size
    }
  end

  @impl true
  def handle_error(error) do
    case error do
      {:error, :timeout} ->
        {:timeout, "WebSocket operation timed out"}
        
      {:error, %WebSockex.ConnError{original: reason}} ->
        {:recoverable, "Connection error: #{inspect(reason)}"}
        
      {:error, :disconnected} ->
        {:recoverable, "WebSocket disconnected"}
        
      {:error, {:close, code, reason}} ->
        if code >= 4000 do
          {:permanent, "Application error: #{reason}"}
        else
          {:recoverable, "Connection closed: #{reason}"}
        end
        
      {:error, reason} ->
        {:recoverable, "Unknown error: #{inspect(reason)}"}
    end
  end

  @impl true
  def subscribe(connection, topic, handler) do
    GenServer.call(connection, {:subscribe, topic, handler})
  end

  @impl true
  def unsubscribe(connection, subscription_ref) do
    GenServer.call(connection, {:unsubscribe, subscription_ref})
  end

  # WebSockex Callbacks

  @impl WebSockex
  def handle_connect(_conn, state) do
    Logger.info("WebSocket connected", connection_id: state.connection_id)
    
    # Start ping timer
    ping_timer = Process.send_after(self(), :ping, @ping_interval)
    
    # Notify handler of connection
    send(state.handler, {:websocket_connected, state.connection_id})
    
    {:ok, %{state | ping_timer: ping_timer}}
  end

  @impl WebSockex
  def handle_disconnect(disconnect_info, state) do
    Logger.warn("WebSocket disconnected", 
      connection_id: state.connection_id,
      reason: disconnect_info
    )
    
    # Cancel ping timer
    if state.ping_timer do
      Process.cancel_timer(state.ping_timer)
    end
    
    # Notify handler
    send(state.handler, {:websocket_disconnected, state.connection_id, disconnect_info})
    
    # Reconnect after interval
    {:reconnect, @reconnect_interval, state}
  end

  @impl WebSockex
  def handle_frame({:text, frame}, state) do
    case Jason.decode(frame) do
      {:ok, message} ->
        handle_message(message, state)
        
      {:error, reason} ->
        Logger.error("Failed to decode WebSocket frame", 
          reason: reason,
          frame: frame
        )
        {:ok, state}
    end
  end

  @impl WebSockex
  def handle_frame({:binary, frame}, state) do
    # Handle binary frames if needed
    handle_binary_message(frame, state)
  end

  @impl WebSockex
  def handle_frame({:ping, data}, state) do
    # Respond with pong
    {:reply, {:pong, data}, state}
  end

  @impl WebSockex
  def handle_frame({:pong, _data}, state) do
    # Record successful pong
    record_heartbeat()
    {:ok, state}
  end

  @impl WebSockex
  def handle_info(:ping, state) do
    # Send ping frame
    ping_timer = Process.send_after(self(), :ping, @ping_interval)
    {:reply, {:ping, ""}, %{state | ping_timer: ping_timer}}
  end

  @impl WebSockex
  def handle_info({:ssl_closed, _}, state) do
    {:close, state}
  end

  @impl WebSockex
  def handle_cast({:send_message, message}, state) do
    case encode_message(message) do
      {:ok, frame} ->
        {:reply, {:text, frame}, state}
        
      {:error, reason} ->
        Logger.error("Failed to encode message", reason: reason)
        {:ok, state}
    end
  end

  @impl WebSockex
  def handle_cast(:disconnect, state) do
    {:close, state}
  end

  # GenServer Callbacks for synchronous operations

  def handle_call({:send_message, message}, from, state) do
    request_id = generate_request_id()
    
    # Store pending request
    pending = Map.put(state.pending_requests, request_id, from)
    
    # Add request ID to message
    message_with_id = Map.put(message, :request_id, request_id)
    
    case encode_message(message_with_id) do
      {:ok, frame} ->
        WebSockex.send_frame(self(), {:text, frame})
        {:noreply, %{state | pending_requests: pending}}
        
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe, topic, handler}, _from, state) do
    subscription_ref = make_ref()
    
    # Send subscription message
    sub_message = %{
      type: "subscribe",
      topic: topic,
      subscription_id: subscription_ref
    }
    
    case encode_message(sub_message) do
      {:ok, frame} ->
        WebSockex.send_frame(self(), {:text, frame})
        
        # Store subscription
        subscriptions = Map.put(state.subscriptions, subscription_ref, {topic, handler})
        {:reply, {:ok, subscription_ref}, %{state | subscriptions: subscriptions}}
        
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unsubscribe, subscription_ref}, _from, state) do
    case Map.fetch(state.subscriptions, subscription_ref) do
      {:ok, {topic, _handler}} ->
        # Send unsubscribe message
        unsub_message = %{
          type: "unsubscribe",
          topic: topic,
          subscription_id: subscription_ref
        }
        
        case encode_message(unsub_message) do
          {:ok, frame} ->
            WebSockex.send_frame(self(), {:text, frame})
            
            # Remove subscription
            subscriptions = Map.delete(state.subscriptions, subscription_ref)
            {:reply, :ok, %{state | subscriptions: subscriptions}}
            
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
        
      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:health_check, _from, state) do
    status = if WebSockex.connected?(self()), do: :connected, else: :disconnected
    {:reply, status, state}
  end

  # Private Functions

  defp handle_message(message, state) do
    # Check if this is a response to a pending request
    case Map.fetch(message, "request_id") do
      {:ok, request_id} ->
        handle_response(request_id, message, state)
        
      :error ->
        # Check if this is a subscription message
        case Map.fetch(message, "subscription_id") do
          {:ok, subscription_ref} ->
            handle_subscription_message(subscription_ref, message, state)
            
          :error ->
            # Regular message - route to VSM
            route_to_vsm(message, state)
        end
    end
  end

  defp handle_response(request_id, message, state) do
    case Map.fetch(state.pending_requests, request_id) do
      {:ok, from} ->
        # Reply to waiting caller
        GenServer.reply(from, {:ok, message})
        
        # Remove from pending
        pending = Map.delete(state.pending_requests, request_id)
        {:ok, %{state | pending_requests: pending}}
        
      :error ->
        # No pending request for this ID
        Logger.warn("Received response for unknown request", request_id: request_id)
        {:ok, state}
    end
  end

  defp handle_subscription_message(subscription_ref, message, state) do
    case Map.fetch(state.subscriptions, subscription_ref) do
      {:ok, {_topic, handler}} ->
        # Call subscription handler
        handler.(message)
        {:ok, state}
        
      :error ->
        Logger.warn("Received message for unknown subscription", 
          subscription_id: subscription_ref
        )
        {:ok, state}
    end
  end

  defp handle_binary_message(data, state) do
    # For binary messages, try to decode as JSON first
    # In a real implementation, this could use MessagePack or Protocol Buffers
    case Jason.decode(data) do
      {:ok, message} ->
        handle_message(message, state)
        
      {:error, _reason} ->
        # If not JSON, log and skip
        Logger.error("Failed to decode binary message - only JSON supported currently")
        {:ok, state}
    end
  end

  defp route_to_vsm(message, state) do
    # Transform to VSM format
    case transform_inbound(message, state.metadata) do
      {:ok, vsm_message} ->
        # Route through message router
        MessageRouter.route_async(vsm_message, fn result ->
          handle_routing_result(result, state)
        end)
        
      {:error, reason} ->
        Logger.error("Failed to transform WebSocket message", reason: reason)
    end
    
    {:ok, state}
  end

  defp handle_routing_result({:ok, _routing_decision}, _state) do
    # Message successfully routed
    record_successful_routing()
  end

  defp handle_routing_result({:error, reason}, _state) do
    Logger.error("Message routing failed", reason: reason)
    record_failed_routing()
  end

  defp encode_message(message) do
    Jason.encode(message)
  rescue
    exception ->
      {:error, exception}
  end

  defp generate_connection_id do
    "ws-#{:erlang.system_time(:microsecond)}-#{:rand.uniform(10000)}"
  end

  defp generate_request_id do
    "req-#{:erlang.system_time(:microsecond)}-#{:rand.uniform(10000)}"
  end

  defp build_metadata(opts) do
    %{
      protocol: :websocket,
      connection_type: :persistent,
      features: [:bidirectional, :streaming],
      custom: Keyword.get(opts, :metadata, %{})
    }
  end

  defp build_headers(opts) do
    headers = Keyword.get(opts, :headers, [])
    
    # Add authentication headers if provided
    auth_headers = case opts[:auth] do
      {:bearer, token} ->
        [{"Authorization", "Bearer #{token}"}]
        
      {:basic, {username, password}} ->
        credentials = Base.encode64("#{username}:#{password}")
        [{"Authorization", "Basic #{credentials}"}]
        
      _ ->
        []
    end
    
    headers ++ auth_headers
  end

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["ws", "wss"] ->
        :ok
        
      _ ->
        {:error, {:invalid_url, "URL must use ws:// or wss:// scheme"}}
    end
  end

  defp record_heartbeat do
    :telemetry.execute(
      [:vsm_connections, :websocket, :heartbeat],
      %{timestamp: System.system_time()},
      %{}
    )
  end

  defp record_successful_routing do
    :telemetry.execute(
      [:vsm_connections, :websocket, :routing],
      %{count: 1},
      %{status: :success}
    )
  end

  defp record_failed_routing do
    :telemetry.execute(
      [:vsm_connections, :websocket, :routing],
      %{count: 1},
      %{status: :failure}
    )
  end

  defp get_connection_count do
    # In a real implementation, query Registry
    0
  end

  defp get_counter(metric) do
    # In a real implementation, query telemetry metrics
    0
  end

  defp get_histogram(metric) do
    # In a real implementation, query telemetry metrics
    0.0
  end
end