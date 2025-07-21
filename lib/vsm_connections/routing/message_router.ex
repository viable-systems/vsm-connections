defmodule VsmConnections.Routing.MessageRouter do
  @moduledoc """
  Routes messages between external systems and VSM subsystems.
  
  The router analyzes incoming messages and determines the appropriate
  VSM subsystem based on content, metadata, and routing rules.
  """

  use GenServer
  require Logger

  alias VsmConnections.Routing.{RoutingRules, RoutingContext}
  alias VsmConnections.Integration.MetricsCollector

  @type route_target :: 
    {:system1, unit :: atom()} |
    {:system2, coordination_type :: atom()} |
    {:system3, control_aspect :: atom()} |
    {:system4, intelligence_type :: atom()} |
    {:system5, policy_domain :: atom()} |
    {:algedonic, severity :: atom()} |
    {:temporal_variety, timescale :: atom()}

  @type routing_decision :: {
    target :: route_target(),
    priority :: :low | :normal | :high | :critical,
    metadata :: map()
  }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Routes a message to the appropriate VSM subsystem.
  
  ## Options
  - `:timeout` - Routing timeout (default: 5000ms)
  - `:trace` - Enable routing trace for debugging
  - `:priority` - Override automatic priority detection
  """
  @spec route(message :: map(), opts :: keyword()) :: {:ok, routing_decision()} | {:error, term()}
  def route(message, opts \\ []) do
    GenServer.call(__MODULE__, {:route, message, opts}, opts[:timeout] || 5_000)
  end

  @doc """
  Routes a message asynchronously.
  
  Useful for fire-and-forget scenarios or when routing latency must be minimized.
  """
  @spec route_async(message :: map(), callback :: function()) :: :ok
  def route_async(message, callback) do
    GenServer.cast(__MODULE__, {:route_async, message, callback})
  end

  @doc """
  Registers a custom routing rule.
  
  Custom rules are evaluated before built-in rules.
  """
  @spec register_rule(rule :: RoutingRules.rule()) :: :ok | {:error, term()}
  def register_rule(rule) do
    GenServer.call(__MODULE__, {:register_rule, rule})
  end

  @doc """
  Updates routing configuration at runtime.
  """
  @spec update_config(config :: map()) :: :ok
  def update_config(config) do
    GenServer.call(__MODULE__, {:update_config, config})
  end

  # Server Implementation

  defmodule State do
    defstruct [
      :config,
      :custom_rules,
      :routing_stats,
      :circuit_breakers,
      :trace_enabled
    ]
  end

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, default_config())
    
    state = %State{
      config: config,
      custom_rules: [],
      routing_stats: %{},
      circuit_breakers: %{},
      trace_enabled: config[:trace_enabled] || false
    }
    
    {:ok, state}
  end

  @impl true
  def handle_call({:route, message, opts}, _from, state) do
    start_time = System.monotonic_time()
    
    case perform_routing(message, opts, state) do
      {:ok, decision} = result ->
        record_metrics(message, decision, start_time, state)
        {:reply, result, state}
        
      {:error, _reason} = error ->
        record_error(message, error, start_time, state)
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:register_rule, rule}, _from, state) do
    case RoutingRules.validate_rule(rule) do
      :ok ->
        new_rules = [rule | state.custom_rules]
        {:reply, :ok, %{state | custom_rules: new_rules}}
        
      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:update_config, config}, _from, state) do
    {:reply, :ok, %{state | config: Map.merge(state.config, config)}}
  end

  @impl true
  def handle_cast({:route_async, message, callback}, state) do
    Task.start(fn ->
      case perform_routing(message, [], state) do
        {:ok, decision} -> callback.({:ok, decision})
        error -> callback.(error)
      end
    end)
    
    {:noreply, state}
  end

  # Private Functions

  defp perform_routing(message, opts, state) do
    context = build_routing_context(message, opts, state)
    
    with {:ok, enriched_message} <- enrich_message(message, context),
         {:ok, target} <- determine_target(enriched_message, context, state),
         {:ok, priority} <- determine_priority(enriched_message, target, context),
         {:ok, metadata} <- build_routing_metadata(enriched_message, target, priority, context) do
      
      decision = {target, priority, metadata}
      
      if state.trace_enabled or opts[:trace] do
        Logger.debug("Routing decision: #{inspect(decision)}")
      end
      
      {:ok, decision}
    end
  end

  defp build_routing_context(message, opts, state) do
    %RoutingContext{
      message: message,
      opts: opts,
      timestamp: DateTime.utc_now(),
      source: extract_source(message),
      correlation_id: message[:correlation_id] || generate_correlation_id(),
      routing_rules: state.custom_rules ++ default_rules()
    }
  end

  defp enrich_message(message, context) do
    enriched = message
    |> Map.put(:routing_timestamp, context.timestamp)
    |> Map.put(:correlation_id, context.correlation_id)
    |> Map.put(:source_system, context.source)
    
    {:ok, enriched}
  end

  defp determine_target(message, context, state) do
    # First check for emergency/algedonic signals
    if algedonic_signal?(message) do
      {:ok, {:algedonic, extract_severity(message)}}
    else
      # Apply custom rules first
      case apply_custom_rules(message, state.custom_rules) do
        {:ok, target} -> {:ok, target}
        :no_match -> apply_default_routing(message, context)
      end
    end
  end

  defp algedonic_signal?(message) do
    message[:emergency] == true or
    message[:severity] in [:critical, :emergency] or
    message[:type] == "algedonic"
  end

  defp extract_severity(message) do
    message[:severity] || :critical
  end

  defp apply_custom_rules(_message, []), do: :no_match
  
  defp apply_custom_rules(message, [rule | rest]) do
    case RoutingRules.evaluate(rule, message) do
      {:match, target} -> {:ok, target}
      :no_match -> apply_custom_rules(message, rest)
    end
  end

  defp apply_default_routing(message, _context) do
    cond do
      operational_message?(message) ->
        {:ok, {:system1, determine_operational_unit(message)}}
        
      coordination_message?(message) ->
        {:ok, {:system2, determine_coordination_type(message)}}
        
      control_message?(message) ->
        {:ok, {:system3, determine_control_aspect(message)}}
        
      intelligence_message?(message) ->
        {:ok, {:system4, determine_intelligence_type(message)}}
        
      policy_message?(message) ->
        {:ok, {:system5, determine_policy_domain(message)}}
        
      temporal_variety_message?(message) ->
        {:ok, {:temporal_variety, determine_timescale(message)}}
        
      true ->
        # Default to System 3 for unknown messages
        {:ok, {:system3, :general}}
    end
  end

  defp operational_message?(message) do
    message[:type] in ["transaction", "operation", "task", "work_item"] or
    message[:subsystem] == "s1" or
    Map.has_key?(message, :operation_id)
  end

  defp coordination_message?(message) do
    message[:type] in ["coordination", "synchronization", "anti_oscillation"] or
    message[:subsystem] == "s2" or
    Map.has_key?(message, :coordination_token)
  end

  defp control_message?(message) do
    message[:type] in ["control", "resource_allocation", "audit", "management"] or
    message[:subsystem] == "s3" or
    Map.has_key?(message, :control_directive)
  end

  defp intelligence_message?(message) do
    message[:type] in ["forecast", "analysis", "environmental_scan", "trend"] or
    message[:subsystem] == "s4" or
    Map.has_key?(message, :intelligence_data)
  end

  defp policy_message?(message) do
    message[:type] in ["policy", "strategy", "decision", "values"] or
    message[:subsystem] == "s5" or
    Map.has_key?(message, :policy_update)
  end

  defp temporal_variety_message?(message) do
    message[:type] == "temporal_variety" or
    Map.has_key?(message, :temporal_data)
  end

  defp determine_operational_unit(message) do
    message[:unit] || :default
  end

  defp determine_coordination_type(message) do
    message[:coordination_type] || :general
  end

  defp determine_control_aspect(message) do
    message[:control_aspect] || :resource_management
  end

  defp determine_intelligence_type(message) do
    message[:intelligence_type] || :environmental_scan
  end

  defp determine_policy_domain(message) do
    message[:policy_domain] || :strategic
  end

  defp determine_timescale(message) do
    message[:timescale] || :minute
  end

  defp determine_priority(message, target, _context) do
    priority = cond do
      # Algedonic signals are always critical
      elem(target, 0) == :algedonic -> :critical
      
      # Check message priority field
      message[:priority] in [:critical, :high, :normal, :low] -> message[:priority]
      
      # System 5 messages default to high
      elem(target, 0) == :system5 -> :high
      
      # Urgent operational messages
      elem(target, 0) == :system1 && message[:urgent] -> :high
      
      # Default priority
      true -> :normal
    end
    
    {:ok, priority}
  end

  defp build_routing_metadata(message, target, priority, context) do
    metadata = %{
      routed_at: DateTime.utc_now(),
      routing_duration_us: 0,  # Can't subtract DateTime from monotonic_time
      target: target,
      priority: priority,
      correlation_id: context.correlation_id,
      source: context.source,
      message_type: message[:type],
      trace_id: generate_trace_id()
    }
    
    {:ok, metadata}
  end

  defp extract_source(message) do
    message[:source] || message[:sender] || "unknown"
  end

  defp generate_correlation_id do
    # Generate a simple unique ID without external dependencies
    "corr-#{:erlang.system_time(:microsecond)}-#{:rand.uniform(10000)}"
  end

  defp generate_trace_id do
    # Generate a simple unique ID without external dependencies
    "trace-#{:erlang.system_time(:microsecond)}-#{:rand.uniform(10000)}"
  end

  defp record_metrics(message, decision, start_time, _state) do
    duration = System.monotonic_time() - start_time
    
    MetricsCollector.record(:routing, %{
      duration_us: duration,
      target: elem(decision, 0),
      priority: elem(decision, 1),
      message_type: message[:type]
    })
  end

  defp record_error(message, error, start_time, _state) do
    duration = System.monotonic_time() - start_time
    
    MetricsCollector.record(:routing_error, %{
      duration_us: duration,
      error: error,
      message_type: message[:type]
    })
  end

  defp default_config do
    %{
      trace_enabled: false,
      max_routing_time_ms: 100,
      default_priority: :normal
    }
  end

  defp default_rules do
    [
      # Add default routing rules here
    ]
  end
end