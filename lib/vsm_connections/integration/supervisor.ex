defmodule VsmConnections.Integration.Supervisor do
  @moduledoc """
  Supervisor for the VSM integration infrastructure.
  
  Manages all integration components including adapters, routers,
  transformation pipelines, and resilience mechanisms.
  """

  use Supervisor
  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("Starting VSM Integration Supervisor")
    
    children = [
      # Configuration Manager - must start first
      {VsmConnections.Configuration.ConfigManager, opts[:config] || []},
      
      # Registry for connection tracking
      {Registry, keys: :unique, name: VsmConnections.Registry},
      
      # Circuit Breaker Manager
      {VsmConnections.Resilience.CircuitBreakerManager, 
        build_circuit_breaker_config(opts)},
      
      # Message Router
      {VsmConnections.Routing.MessageRouter,
        build_router_config(opts)},
      
      # Adapter Supervisors
      {VsmConnections.Adapters.Supervisor,
        build_adapter_config(opts)},
      
      # Metrics Collector
      {VsmConnections.Integration.MetricsCollector, []},
      
      # Health Monitor
      {VsmConnections.Integration.HealthMonitor,
        build_health_config(opts)},
      
      # Integration Manager - coordinates everything
      {VsmConnections.Integration.Manager, opts}
    ]
    
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  defp build_circuit_breaker_config(opts) do
    default_breakers = %{
      http_adapter: %{
        failure_threshold: 5,
        recovery_timeout: 60_000,
        call_timeout: 5_000
      },
      websocket_adapter: %{
        failure_threshold: 3,
        recovery_timeout: 30_000,
        call_timeout: 10_000
      },
      grpc_adapter: %{
        failure_threshold: 5,
        recovery_timeout: 45_000,
        call_timeout: 5_000
      }
    }
    
    breakers = Keyword.get(opts, :circuit_breakers, %{})
    
    [
      breakers: Map.merge(default_breakers, breakers),
      algedonic_threshold: opts[:algedonic_threshold] || 0.8,
      vsm_integration: true
    ]
  end

  defp build_router_config(opts) do
    [
      config: %{
        trace_enabled: opts[:trace_routing] || false,
        max_routing_time_ms: opts[:max_routing_time] || 100,
        default_priority: :normal
      }
    ]
  end

  defp build_adapter_config(opts) do
    [
      adapters: opts[:adapters] || [:http, :websocket, :grpc],
      pools: opts[:pools] || %{},
      default_timeout: opts[:default_timeout] || 5_000
    ]
  end

  defp build_health_config(opts) do
    [
      check_interval: opts[:health_check_interval] || 30_000,
      adapters: opts[:adapters] || [:http, :websocket, :grpc],
      vsm_integration: true
    ]
  end
end

defmodule VsmConnections.Adapters.Supervisor do
  @moduledoc """
  Supervisor for protocol adapters.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    adapters = Keyword.get(opts, :adapters, [:http, :websocket, :grpc])
    
    children = Enum.map(adapters, fn adapter ->
      case adapter do
        :http ->
          {VsmConnections.Adapters.HttpPool, build_http_config(opts)}
          
        :websocket ->
          {VsmConnections.Adapters.WebSocketPool, build_websocket_config(opts)}
          
        :grpc ->
          {VsmConnections.Adapters.GrpcPool, build_grpc_config(opts)}
          
        custom when is_atom(custom) ->
          # Support for custom adapters
          {custom, Keyword.get(opts, custom, [])}
      end
    end)
    
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_http_config(opts) do
    pools = Keyword.get(opts, :pools, %{})
    http_pools = Map.get(pools, :http, %{})
    
    [
      pools: http_pools,
      default_timeout: opts[:default_timeout] || 5_000
    ]
  end

  defp build_websocket_config(opts) do
    pools = Keyword.get(opts, :pools, %{})
    ws_pools = Map.get(pools, :websocket, %{})
    
    [
      pools: ws_pools,
      ping_interval: 30_000,
      reconnect_interval: 5_000
    ]
  end

  defp build_grpc_config(opts) do
    pools = Keyword.get(opts, :pools, %{})
    grpc_pools = Map.get(pools, :grpc, %{})
    
    [
      pools: grpc_pools,
      default_timeout: opts[:default_timeout] || 5_000
    ]
  end
end

defmodule VsmConnections.Integration.Manager do
  @moduledoc """
  Main integration manager that coordinates all components.
  
  Provides the high-level API for external system integration.
  """

  use GenServer
  require Logger

  alias VsmConnections.{
    Adapters,
    Routing.MessageRouter,
    Transformation.Pipeline,
    Resilience.CircuitBreakerManager,
    Configuration.ConfigManager
  }

  defmodule State do
    defstruct [
      :adapters,
      :active_connections,
      :stats,
      :config
    ]
  end

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Sends a message through the integration layer.
  
  Automatically handles:
  - Protocol selection
  - Circuit breaking
  - Message transformation
  - Routing to VSM
  """
  def send_message(message, opts \\ []) do
    GenServer.call(__MODULE__, {:send_message, message, opts})
  end

  @doc """
  Establishes a connection to an external system.
  """
  def connect(protocol, connection_opts) do
    GenServer.call(__MODULE__, {:connect, protocol, connection_opts})
  end

  @doc """
  Disconnects from an external system.
  """
  def disconnect(connection_ref) do
    GenServer.call(__MODULE__, {:disconnect, connection_ref})
  end

  @doc """
  Gets integration statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # Server Implementation

  @impl true
  def init(opts) do
    # Register with config manager for updates
    ConfigManager.register_change_listener(&handle_config_change/3)
    
    state = %State{
      adapters: %{},
      active_connections: %{},
      stats: initialize_stats(),
      config: opts
    }
    
    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, message, opts}, _from, state) do
    protocol = determine_protocol(message, opts)
    
    result = with {:ok, adapter} <- get_adapter(protocol, state),
                  {:ok, transformed} <- transform_outbound(message, protocol),
                  {:ok, response} <- send_with_circuit_breaker(adapter, transformed, opts) do
      
      # Route response back through VSM
      route_response(response, message)
      {:ok, response}
    end
    
    {:reply, result, update_stats(state, protocol, result)}
  end

  @impl true
  def handle_call({:connect, protocol, connection_opts}, _from, state) do
    case get_adapter_module(protocol) do
      {:ok, adapter_module} ->
        case adapter_module.connect(connection_opts) do
          {:ok, connection} ->
            ref = make_ref()
            connections = Map.put(state.active_connections, ref, {protocol, connection})
            
            {:reply, {:ok, ref}, %{state | active_connections: connections}}
            
          {:error, _} = error ->
            {:reply, error, state}
        end
        
      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:disconnect, connection_ref}, _from, state) do
    case Map.fetch(state.active_connections, connection_ref) do
      {:ok, {protocol, connection}} ->
        adapter_module = get_adapter_module!(protocol)
        adapter_module.disconnect(connection)
        
        connections = Map.delete(state.active_connections, connection_ref)
        {:reply, :ok, %{state | active_connections: connections}}
        
      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = compile_stats(state)
    {:reply, stats, state}
  end

  # Private Functions

  defp determine_protocol(message, opts) do
    opts[:protocol] || message[:protocol] || :http
  end

  defp get_adapter(protocol, _state) do
    case get_adapter_module(protocol) do
      {:ok, _module} -> {:ok, protocol}
      error -> error
    end
  end

  defp get_adapter_module(protocol) do
    case protocol do
      :http -> {:ok, VsmConnections.Adapters.HttpAdapter}
      :websocket -> {:ok, VsmConnections.Adapters.WebSocketAdapter}
      :grpc -> {:ok, VsmConnections.Adapters.GrpcAdapter}
      _ -> {:error, {:unknown_protocol, protocol}}
    end
  end

  defp get_adapter_module!(protocol) do
    {:ok, module} = get_adapter_module(protocol)
    module
  end

  defp transform_outbound(message, protocol) do
    pipeline = get_outbound_pipeline(protocol)
    Pipeline.transform(message, pipeline)
  end

  defp get_outbound_pipeline(:http), do: Pipeline.vsm_to_http_pipeline()
  defp get_outbound_pipeline(:websocket), do: Pipeline.websocket_pipeline()
  defp get_outbound_pipeline(:grpc), do: Pipeline.grpc_pipeline()
  defp get_outbound_pipeline(_), do: []

  defp send_with_circuit_breaker(adapter, message, opts) do
    breaker_name = :"#{adapter}_adapter"
    
    CircuitBreakerManager.call(breaker_name, fn ->
      adapter_module = get_adapter_module!(adapter)
      
      # Get or create connection
      connection = get_connection(adapter, opts)
      
      adapter_module.send(connection, message)
    end, opts)
  end

  defp get_connection(adapter, opts) do
    # In a real implementation, this would manage connection pooling
    adapter_module = get_adapter_module!(adapter)
    {:ok, connection} = adapter_module.connect(opts)
    connection
  end

  defp route_response(response, original_message) do
    routing_message = %{
      type: :integration_response,
      response: response,
      original_message: original_message,
      timestamp: DateTime.utc_now()
    }
    
    MessageRouter.route_async(routing_message, fn result ->
      Logger.debug("Response routed", result: result)
    end)
  end

  defp handle_config_change(component, _old_config, new_config) do
    Logger.info("Configuration changed", component: component)
    
    # Handle specific component updates
    case component do
      :integration_manager ->
        # Update our own config
        GenServer.cast(__MODULE__, {:update_config, new_config})
        
      _ ->
        :ok
    end
  end

  defp initialize_stats do
    %{
      messages_sent: 0,
      messages_received: 0,
      errors: 0,
      by_protocol: %{},
      start_time: DateTime.utc_now()
    }
  end

  defp update_stats(state, protocol, result) do
    stats = state.stats
    
    protocol_stats = Map.get(stats.by_protocol, protocol, %{sent: 0, errors: 0})
    
    updated_protocol_stats = case result do
      {:ok, _} ->
        %{protocol_stats | sent: protocol_stats.sent + 1}
        
      {:error, _} ->
        %{protocol_stats | 
          sent: protocol_stats.sent + 1,
          errors: protocol_stats.errors + 1
        }
    end
    
    updated_stats = %{stats |
      messages_sent: stats.messages_sent + 1,
      errors: if(match?({:error, _}, result), do: stats.errors + 1, else: stats.errors),
      by_protocol: Map.put(stats.by_protocol, protocol, updated_protocol_stats)
    }
    
    %{state | stats: updated_stats}
  end

  defp compile_stats(state) do
    uptime = DateTime.diff(DateTime.utc_now(), state.stats.start_time, :second)
    
    %{
      uptime_seconds: uptime,
      total_messages: state.stats.messages_sent,
      total_errors: state.stats.errors,
      error_rate: calculate_error_rate(state.stats),
      by_protocol: state.stats.by_protocol,
      active_connections: map_size(state.active_connections),
      circuit_breakers: get_circuit_breaker_stats()
    }
  end

  defp calculate_error_rate(%{messages_sent: 0}), do: 0.0
  defp calculate_error_rate(%{messages_sent: sent, errors: errors}) do
    errors / sent
  end

  defp get_circuit_breaker_stats do
    [:http_adapter, :websocket_adapter, :grpc_adapter]
    |> Enum.map(fn breaker ->
      {breaker, CircuitBreakerManager.get_stats(breaker)}
    end)
    |> Map.new()
  end
end

defmodule VsmConnections.Integration.MetricsCollector do
  @moduledoc """
  Collects and aggregates metrics from all integration components.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def record(metric, data) do
    GenServer.cast(__MODULE__, {:record, metric, data})
  end

  @impl true
  def init(_opts) do
    # Setup telemetry handlers
    setup_telemetry_handlers()
    
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:record, metric, data}, state) do
    # Record metric
    :telemetry.execute(
      [:vsm_connections, :integration, metric],
      data,
      %{}
    )
    
    {:noreply, state}
  end

  defp setup_telemetry_handlers do
    :telemetry.attach_many(
      "vsm-connections-metrics",
      [
        [:vsm_connections, :integration, :routing],
        [:vsm_connections, :adapter, :request],
        [:vsm_connections, :transformation, :stage],
        [:vsm_connections, :circuit_breaker, :state_change]
      ],
      &handle_telemetry_event/4,
      nil
    )
  end

  defp handle_telemetry_event(event, measurements, metadata, _config) do
    # Log or forward to monitoring system
    Logger.debug("Telemetry event", 
      event: event,
      measurements: measurements,
      metadata: metadata
    )
  end
end

defmodule VsmConnections.Integration.HealthMonitor do
  @moduledoc """
  Monitors the health of all integration components and external connections.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Schedule first health check
    schedule_health_check(opts[:check_interval] || 30_000)
    
    {:ok, %{opts: opts, health_status: %{}}}
  end

  @impl true
  def handle_info(:health_check, state) do
    # Check all components
    health_status = perform_health_checks(state.opts)
    
    # Log any unhealthy components
    Enum.each(health_status, fn {component, status} ->
      if status != :healthy do
        Logger.warn("Unhealthy component detected", 
          component: component,
          status: status
        )
      end
    end)
    
    # Schedule next check
    schedule_health_check(state.opts[:check_interval] || 30_000)
    
    {:noreply, %{state | health_status: health_status}}
  end

  defp perform_health_checks(opts) do
    adapters = opts[:adapters] || [:http, :websocket, :grpc]
    
    adapter_health = Enum.map(adapters, fn adapter ->
      module = get_adapter_module(adapter)
      {adapter, check_adapter_health(module)}
    end)
    
    circuit_breaker_health = check_circuit_breakers()
    
    Map.merge(Map.new(adapter_health), circuit_breaker_health)
  end

  defp get_adapter_module(:http), do: VsmConnections.Adapters.HttpAdapter
  defp get_adapter_module(:websocket), do: VsmConnections.Adapters.WebSocketAdapter
  defp get_adapter_module(:grpc), do: VsmConnections.Adapters.GrpcAdapter

  defp check_adapter_health(module) do
    # This would check actual adapter health
    :healthy
  end

  defp check_circuit_breakers do
    %{
      circuit_breakers: :healthy
    }
  end

  defp schedule_health_check(interval) do
    Process.send_after(self(), :health_check, interval)
  end
end