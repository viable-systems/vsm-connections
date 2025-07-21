defmodule VsmConnections.Resilience.CircuitBreakerManager do
  @moduledoc """
  Manages circuit breakers for external connections with VSM integration.
  
  Provides per-adapter circuit breakers with configurable thresholds,
  recovery strategies, and algedonic channel integration for critical failures.
  """

  use GenServer
  require Logger

  alias VsmConnections.Resilience.{CircuitBreaker, RetryPolicy}

  # Circuit breaker states
  @type breaker_state :: :closed | :open | :half_open
  
  # Circuit breaker record
  defmodule BreakerInfo do
    defstruct [
      :name,
      :state,
      :failure_count,
      :success_count,
      :last_failure_time,
      :last_success_time,
      :open_time,
      :half_open_tests,
      :config,
      :metadata
    ]
  end

  defmodule State do
    defstruct [
      :breakers,
      :config,
      :algedonic_threshold,
      :vsm_integration
    ]
  end

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Executes a function through a circuit breaker.
  
  The circuit breaker will automatically open if too many failures occur,
  preventing further calls until the recovery timeout expires.
  """
  @spec call(breaker_name :: atom(), fun :: function(), opts :: keyword()) :: 
    {:ok, term()} | {:error, :circuit_open} | {:error, term()}
  def call(breaker_name, fun, opts \\ []) do
    timeout = opts[:timeout] || 5_000
    
    GenServer.call(__MODULE__, {:call, breaker_name, fun, opts}, timeout + 1_000)
  catch
    :exit, {:timeout, _} ->
      {:error, :timeout}
  end

  @doc """
  Gets the current state of a circuit breaker.
  """
  @spec get_state(breaker_name :: atom()) :: breaker_state()
  def get_state(breaker_name) do
    GenServer.call(__MODULE__, {:get_state, breaker_name})
  end

  @doc """
  Gets detailed statistics for a circuit breaker.
  """
  @spec get_stats(breaker_name :: atom()) :: map()
  def get_stats(breaker_name) do
    GenServer.call(__MODULE__, {:get_stats, breaker_name})
  end

  @doc """
  Manually opens a circuit breaker.
  
  Useful for administrative intervention or coordinated maintenance.
  """
  @spec open(breaker_name :: atom()) :: :ok
  def open(breaker_name) do
    GenServer.call(__MODULE__, {:manual_control, breaker_name, :open})
  end

  @doc """
  Manually closes a circuit breaker.
  """
  @spec close(breaker_name :: atom()) :: :ok
  def close(breaker_name) do
    GenServer.call(__MODULE__, {:manual_control, breaker_name, :close})
  end

  @doc """
  Resets a circuit breaker's counters and state.
  """
  @spec reset(breaker_name :: atom()) :: :ok
  def reset(breaker_name) do
    GenServer.call(__MODULE__, {:reset, breaker_name})
  end

  @doc """
  Registers a new circuit breaker with custom configuration.
  """
  @spec register(breaker_name :: atom(), config :: map()) :: :ok | {:error, :already_exists}
  def register(breaker_name, config) do
    GenServer.call(__MODULE__, {:register, breaker_name, config})
  end

  # Server Implementation

  @impl true
  def init(opts) do
    config = build_config(opts)
    
    # Initialize breakers from configuration
    breakers = initialize_breakers(config.breakers)
    
    # Schedule periodic health checks
    schedule_health_check()
    
    state = %State{
      breakers: breakers,
      config: config,
      algedonic_threshold: config[:algedonic_threshold] || 0.8,
      vsm_integration: config[:vsm_integration] || true
    }
    
    {:ok, state}
  end

  @impl true
  def handle_call({:call, breaker_name, fun, opts}, from, state) do
    case Map.fetch(state.breakers, breaker_name) do
      {:ok, breaker} ->
        handle_breaker_call(breaker, fun, opts, from, state)
        
      :error ->
        # Auto-create breaker with defaults
        breaker = create_default_breaker(breaker_name)
        breakers = Map.put(state.breakers, breaker_name, breaker)
        new_state = %{state | breakers: breakers}
        handle_breaker_call(breaker, fun, opts, from, new_state)
    end
  end

  @impl true
  def handle_call({:get_state, breaker_name}, _from, state) do
    breaker_state = case Map.fetch(state.breakers, breaker_name) do
      {:ok, breaker} -> breaker.state
      :error -> :unknown
    end
    
    {:reply, breaker_state, state}
  end

  @impl true
  def handle_call({:get_stats, breaker_name}, _from, state) do
    stats = case Map.fetch(state.breakers, breaker_name) do
      {:ok, breaker} ->
        build_stats(breaker)
        
      :error ->
        %{error: :not_found}
    end
    
    {:reply, stats, state}
  end

  @impl true
  def handle_call({:manual_control, breaker_name, action}, _from, state) do
    case Map.fetch(state.breakers, breaker_name) do
      {:ok, breaker} ->
        updated_breaker = apply_manual_control(breaker, action)
        breakers = Map.put(state.breakers, breaker_name, updated_breaker)
        
        Logger.info("Circuit breaker manually #{action}ed", 
          breaker: breaker_name,
          action: action
        )
        
        {:reply, :ok, %{state | breakers: breakers}}
        
      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:reset, breaker_name}, _from, state) do
    case Map.fetch(state.breakers, breaker_name) do
      {:ok, breaker} ->
        reset_breaker = %{breaker | 
          state: :closed,
          failure_count: 0,
          success_count: 0,
          last_failure_time: nil,
          last_success_time: nil,
          open_time: nil,
          half_open_tests: 0
        }
        
        breakers = Map.put(state.breakers, breaker_name, reset_breaker)
        
        Logger.info("Circuit breaker reset", breaker: breaker_name)
        
        {:reply, :ok, %{state | breakers: breakers}}
        
      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:register, breaker_name, config}, _from, state) do
    if Map.has_key?(state.breakers, breaker_name) do
      {:reply, {:error, :already_exists}, state}
    else
      breaker = create_breaker(breaker_name, config)
      breakers = Map.put(state.breakers, breaker_name, breaker)
      
      {:reply, :ok, %{state | breakers: breakers}}
    end
  end

  @impl true
  def handle_info(:health_check, state) do
    # Check all breakers and potentially transition states
    breakers = Enum.reduce(state.breakers, %{}, fn {name, breaker}, acc ->
      updated_breaker = check_breaker_health(breaker, state)
      Map.put(acc, name, updated_breaker)
    end)
    
    # Schedule next health check
    schedule_health_check()
    
    {:noreply, %{state | breakers: breakers}}
  end

  @impl true
  def handle_info({:timeout_transition, breaker_name}, state) do
    case Map.fetch(state.breakers, breaker_name) do
      {:ok, breaker} ->
        updated_breaker = handle_timeout_transition(breaker)
        breakers = Map.put(state.breakers, breaker_name, updated_breaker)
        {:noreply, %{state | breakers: breakers}}
        
      :error ->
        {:noreply, state}
    end
  end

  # Private Functions

  defp handle_breaker_call(breaker, fun, opts, from, state) do
    case breaker.state do
      :closed ->
        execute_with_breaker(breaker, fun, opts, from, state)
        
      :open ->
        if should_attempt_recovery?(breaker) do
          # Transition to half-open and try
          half_open_breaker = %{breaker | state: :half_open, half_open_tests: 0}
          execute_with_breaker(half_open_breaker, fun, opts, from, state)
        else
          {:reply, {:error, :circuit_open}, state}
        end
        
      :half_open ->
        if breaker.half_open_tests < breaker.config.half_open_requests do
          execute_with_breaker(breaker, fun, opts, from, state)
        else
          {:reply, {:error, :circuit_open}, state}
        end
    end
  end

  defp execute_with_breaker(breaker, fun, opts, from, state) do
    # Spawn a task to execute the function
    task = Task.async(fn ->
      try do
        result = fun.()
        {:ok, result}
      rescue
        exception ->
          {:error, {:exception, exception}}
      catch
        kind, reason ->
          {:error, {kind, reason}}
      end
    end)
    
    # Wait for result with timeout
    timeout = opts[:timeout] || breaker.config.call_timeout
    
    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, result}} ->
        # Success - update breaker
        updated_breaker = handle_success(breaker)
        breakers = Map.put(state.breakers, breaker.name, updated_breaker)
        {:reply, {:ok, result}, %{state | breakers: breakers}}
        
      {:ok, {:error, reason}} ->
        # Failure - update breaker
        updated_breaker = handle_failure(breaker, reason, state)
        breakers = Map.put(state.breakers, breaker.name, updated_breaker)
        {:reply, {:error, reason}, %{state | breakers: breakers}}
        
      nil ->
        # Timeout
        updated_breaker = handle_failure(breaker, :timeout, state)
        breakers = Map.put(state.breakers, breaker.name, updated_breaker)
        {:reply, {:error, :timeout}, %{state | breakers: breakers}}
    end
  end

  defp handle_success(breaker) do
    success_count = breaker.success_count + 1
    
    updated_breaker = %{breaker |
      success_count: success_count,
      last_success_time: DateTime.utc_now()
    }
    
    # Check if we should close from half-open
    if breaker.state == :half_open do
      if success_count >= breaker.config.success_threshold do
        Logger.info("Circuit breaker closing after recovery", breaker: breaker.name)
        %{updated_breaker | 
          state: :closed,
          failure_count: 0,
          half_open_tests: 0
        }
      else
        %{updated_breaker | half_open_tests: breaker.half_open_tests + 1}
      end
    else
      updated_breaker
    end
  end

  defp handle_failure(breaker, reason, state) do
    failure_count = breaker.failure_count + 1
    
    updated_breaker = %{breaker |
      failure_count: failure_count,
      last_failure_time: DateTime.utc_now()
    }
    
    # Check if we should open the circuit
    if should_open_circuit?(updated_breaker) do
      Logger.warn("Circuit breaker opening", 
        breaker: breaker.name,
        failures: failure_count,
        reason: reason
      )
      
      # Schedule transition to half-open
      Process.send_after(
        self(), 
        {:timeout_transition, breaker.name}, 
        breaker.config.recovery_timeout
      )
      
      # Check if we should send algedonic signal
      maybe_send_algedonic_signal(updated_breaker, state)
      
      %{updated_breaker | 
        state: :open,
        open_time: DateTime.utc_now()
      }
    else
      updated_breaker
    end
  end

  defp should_open_circuit?(breaker) do
    case breaker.state do
      :closed ->
        breaker.failure_count >= breaker.config.failure_threshold
        
      :half_open ->
        # Any failure in half-open state reopens the circuit
        true
        
      :open ->
        false
    end
  end

  defp should_attempt_recovery?(breaker) do
    case breaker.open_time do
      nil -> false
      open_time ->
        elapsed = DateTime.diff(DateTime.utc_now(), open_time, :millisecond)
        elapsed >= breaker.config.recovery_timeout
    end
  end

  defp handle_timeout_transition(breaker) do
    if breaker.state == :open do
      Logger.info("Circuit breaker transitioning to half-open", breaker: breaker.name)
      %{breaker | state: :half_open, half_open_tests: 0}
    else
      breaker
    end
  end

  defp maybe_send_algedonic_signal(breaker, state) do
    if state.vsm_integration do
      failure_rate = calculate_failure_rate(breaker)
      
      if failure_rate >= state.algedonic_threshold do
        send_algedonic_signal(breaker, failure_rate)
      end
    end
  end

  defp calculate_failure_rate(breaker) do
    total = breaker.failure_count + breaker.success_count
    if total > 0 do
      breaker.failure_count / total
    else
      0.0
    end
  end

  defp send_algedonic_signal(breaker, failure_rate) do
    Logger.error("Sending algedonic signal for circuit breaker", 
      breaker: breaker.name,
      failure_rate: failure_rate
    )
    
    # Send to VSM algedonic channel
    message = %{
      type: :algedonic,
      severity: :critical,
      source: :circuit_breaker,
      breaker_name: breaker.name,
      failure_rate: failure_rate,
      timestamp: DateTime.utc_now(),
      message: "Circuit breaker #{breaker.name} experiencing critical failure rate"
    }
    
    # This would integrate with VSM Core's algedonic channel
    VsmCore.Channels.Algedonic.alert(message)
  rescue
    exception ->
      Logger.error("Failed to send algedonic signal", exception: exception)
  end

  defp check_breaker_health(breaker, _state) do
    # Implement health check logic
    # Could check age of last failure, success rates, etc.
    breaker
  end

  defp build_stats(breaker) do
    %{
      name: breaker.name,
      state: breaker.state,
      failure_count: breaker.failure_count,
      success_count: breaker.success_count,
      failure_rate: calculate_failure_rate(breaker),
      last_failure_time: breaker.last_failure_time,
      last_success_time: breaker.last_success_time,
      open_duration: calculate_open_duration(breaker),
      config: breaker.config
    }
  end

  defp calculate_open_duration(breaker) do
    case breaker.open_time do
      nil -> 0
      open_time -> DateTime.diff(DateTime.utc_now(), open_time, :second)
    end
  end

  defp apply_manual_control(breaker, :open) do
    %{breaker | 
      state: :open,
      open_time: DateTime.utc_now()
    }
  end

  defp apply_manual_control(breaker, :close) do
    %{breaker | 
      state: :closed,
      failure_count: 0,
      open_time: nil,
      half_open_tests: 0
    }
  end

  defp create_default_breaker(name) do
    config = %{
      failure_threshold: 5,
      success_threshold: 3,
      recovery_timeout: 60_000,
      call_timeout: 5_000,
      half_open_requests: 3
    }
    
    create_breaker(name, config)
  end

  defp create_breaker(name, config) do
    %BreakerInfo{
      name: name,
      state: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure_time: nil,
      last_success_time: nil,
      open_time: nil,
      half_open_tests: 0,
      config: config,
      metadata: %{}
    }
  end

  defp initialize_breakers(breaker_configs) do
    Enum.reduce(breaker_configs, %{}, fn {name, config}, acc ->
      breaker = create_breaker(name, config)
      Map.put(acc, name, breaker)
    end)
  end

  defp build_config(opts) do
    default_config = %{
      breakers: %{},
      health_check_interval: 30_000,
      algedonic_threshold: 0.8,
      vsm_integration: true
    }
    
    Map.merge(default_config, Map.new(opts))
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, 30_000)
  end
end