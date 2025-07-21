defmodule VsmConnections.CircuitBreaker do
  @moduledoc """
  Circuit breaker implementation for fault tolerance in VSM Connections.
  
  The circuit breaker pattern prevents cascading failures by monitoring
  service health and automatically stopping requests to failing services.
  
  ## States
  
  - **Closed**: Normal operation, requests pass through
  - **Open**: Service is failing, requests are rejected immediately
  - **Half-Open**: Testing if service has recovered
  
  ## Features
  
  - Configurable failure thresholds
  - Automatic recovery attempts
  - Exponential backoff for recovery
  - Real-time state monitoring
  - Integration with VSM telemetry
  """

  use GenServer

  alias VsmConnections.Config
  alias VsmConnections.CircuitBreaker.{State, Config, Supervisor}

  @type circuit_state :: :closed | :open | :half_open
  @type call_result :: {:ok, term()} | {:error, term()}

  defstruct [
    :name,
    :state,
    :failure_count,
    :success_count,
    :last_failure_time,
    :config
  ]

  @doc """
  Starts a circuit breaker with the given name and configuration.
  """
  def start_link({name, config}) do
    GenServer.start_link(__MODULE__, {name, config}, name: via_tuple(name))
  end

  @doc """
  Calls a function through the circuit breaker.
  
  ## Examples
  
      {:ok, result} = VsmConnections.CircuitBreaker.call(:api_service, fn ->
        make_api_call()
      end)
      
      {:error, :circuit_open} = VsmConnections.CircuitBreaker.call(:failing_service, fn ->
        failing_call()
      end)
  """
  @spec call(atom(), function()) :: call_result()
  def call(name, fun) when is_function(fun, 0) do
    GenServer.call(via_tuple(name), {:call, fun})
  end

  @doc """
  Gets the current state of a circuit breaker.
  
  ## Examples
  
      :closed = VsmConnections.CircuitBreaker.get_state(:api_service)
      :open = VsmConnections.CircuitBreaker.get_state(:failing_service)
  """
  @spec get_state(atom()) :: circuit_state()
  def get_state(name) do
    GenServer.call(via_tuple(name), :get_state)
  end

  @doc """
  Gets detailed statistics for a circuit breaker.
  
  ## Examples
  
      %{
        state: :closed,
        failure_count: 0,
        success_count: 100,
        last_failure_time: nil
      } = VsmConnections.CircuitBreaker.get_stats(:api_service)
  """
  @spec get_stats(atom()) :: map()
  def get_stats(name) do
    GenServer.call(via_tuple(name), :get_stats)
  end

  @doc """
  Gets statistics for all circuit breakers.
  """
  @spec get_all_stats() :: %{atom() => map()}
  def get_all_stats do
    Supervisor.list_circuit_breakers()
    |> Enum.map(fn name ->
      {name, get_stats(name)}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Manually opens a circuit breaker.
  
  This can be useful for maintenance or emergency scenarios.
  
  ## Examples
  
      :ok = VsmConnections.CircuitBreaker.open(:api_service)
  """
  @spec open(atom()) :: :ok
  def open(name) do
    GenServer.call(via_tuple(name), :open)
  end

  @doc """
  Manually closes a circuit breaker.
  
  ## Examples
  
      :ok = VsmConnections.CircuitBreaker.close(:api_service)
  """
  @spec close(atom()) :: :ok
  def close(name) do
    GenServer.call(via_tuple(name), :close)
  end

  @doc """
  Resets a circuit breaker to its initial state.
  
  ## Examples
  
      :ok = VsmConnections.CircuitBreaker.reset(:api_service)
  """
  @spec reset(atom()) :: :ok
  def reset(name) do
    GenServer.call(via_tuple(name), :reset)
  end

  # GenServer callbacks

  @impl true
  def init({name, config}) do
    circuit_breaker = %__MODULE__{
      name: name,
      state: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure_time: nil,
      config: Config.new(config)
    }
    
    {:ok, circuit_breaker}
  end

  @impl true
  def handle_call({:call, fun}, _from, circuit_breaker) do
    case can_execute?(circuit_breaker) do
      true ->
        execute_call(fun, circuit_breaker)
      false ->
        emit_telemetry(circuit_breaker.name, :rejected)
        {:reply, {:error, :circuit_open}, circuit_breaker}
    end
  end

  def handle_call(:get_state, _from, circuit_breaker) do
    {:reply, circuit_breaker.state, circuit_breaker}
  end

  def handle_call(:get_stats, _from, circuit_breaker) do
    stats = %{
      name: circuit_breaker.name,
      state: circuit_breaker.state,
      failure_count: circuit_breaker.failure_count,
      success_count: circuit_breaker.success_count,
      last_failure_time: circuit_breaker.last_failure_time,
      config: circuit_breaker.config
    }
    {:reply, stats, circuit_breaker}
  end

  def handle_call(:open, _from, circuit_breaker) do
    new_circuit_breaker = transition_to_open(circuit_breaker, :manual)
    {:reply, :ok, new_circuit_breaker}
  end

  def handle_call(:close, _from, circuit_breaker) do
    new_circuit_breaker = transition_to_closed(circuit_breaker)
    {:reply, :ok, new_circuit_breaker}
  end

  def handle_call(:reset, _from, circuit_breaker) do
    new_circuit_breaker = %{circuit_breaker |
      state: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure_time: nil
    }
    
    emit_state_change_telemetry(circuit_breaker.name, circuit_breaker.state, :closed)
    {:reply, :ok, new_circuit_breaker}
  end

  @impl true
  def handle_info(:recovery_timeout, circuit_breaker) do
    case circuit_breaker.state do
      :open ->
        new_circuit_breaker = transition_to_half_open(circuit_breaker)
        {:noreply, new_circuit_breaker}
      _ ->
        {:noreply, circuit_breaker}
    end
  end

  # Private functions

  defp via_tuple(name) do
    {:via, Registry, {VsmConnections.CircuitBreaker.Registry, name}}
  end

  defp can_execute?(%{state: :closed}), do: true
  defp can_execute?(%{state: :half_open}), do: true
  defp can_execute?(%{state: :open}), do: false

  defp execute_call(fun, circuit_breaker) do
    start_time = System.monotonic_time()
    
    try do
      result = fun.()
      end_time = System.monotonic_time()
      duration = end_time - start_time
      
      handle_success(result, circuit_breaker, duration)
    catch
      kind, reason ->
        end_time = System.monotonic_time()
        duration = end_time - start_time
        
        error = {:error, {kind, reason}}
        handle_failure(error, circuit_breaker, duration)
    end
  end

  defp handle_success({:ok, _result} = success, circuit_breaker, duration) do
    new_circuit_breaker = record_success(circuit_breaker)
    emit_telemetry(circuit_breaker.name, :success, duration)
    
    {:reply, success, new_circuit_breaker}
  end

  defp handle_success({:error, _reason} = error, circuit_breaker, duration) do
    handle_failure(error, circuit_breaker, duration)
  end

  defp handle_success(result, circuit_breaker, duration) do
    # Treat any non-error tuple as success
    new_circuit_breaker = record_success(circuit_breaker)
    emit_telemetry(circuit_breaker.name, :success, duration)
    
    {:reply, {:ok, result}, new_circuit_breaker}
  end

  defp handle_failure(error, circuit_breaker, duration) do
    new_circuit_breaker = record_failure(circuit_breaker)
    emit_telemetry(circuit_breaker.name, :failure, duration)
    
    {:reply, error, new_circuit_breaker}
  end

  defp record_success(circuit_breaker) do
    new_circuit_breaker = %{circuit_breaker |
      success_count: circuit_breaker.success_count + 1
    }
    
    case circuit_breaker.state do
      :half_open ->
        if new_circuit_breaker.success_count >= circuit_breaker.config.success_threshold do
          transition_to_closed(new_circuit_breaker)
        else
          new_circuit_breaker
        end
      _ ->
        new_circuit_breaker
    end
  end

  defp record_failure(circuit_breaker) do
    now = System.system_time(:millisecond)
    
    new_circuit_breaker = %{circuit_breaker |
      failure_count: circuit_breaker.failure_count + 1,
      last_failure_time: now
    }
    
    case circuit_breaker.state do
      :closed ->
        if new_circuit_breaker.failure_count >= circuit_breaker.config.failure_threshold do
          transition_to_open(new_circuit_breaker, :failure_threshold)
        else
          new_circuit_breaker
        end
      
      :half_open ->
        transition_to_open(new_circuit_breaker, :half_open_failure)
      
      :open ->
        new_circuit_breaker
    end
  end

  defp transition_to_open(circuit_breaker, reason) do
    new_circuit_breaker = %{circuit_breaker | state: :open}
    
    # Schedule recovery attempt
    recovery_timeout = circuit_breaker.config.recovery_timeout
    Process.send_after(self(), :recovery_timeout, recovery_timeout)
    
    emit_state_change_telemetry(circuit_breaker.name, circuit_breaker.state, :open, reason)
    
    new_circuit_breaker
  end

  defp transition_to_half_open(circuit_breaker) do
    new_circuit_breaker = %{circuit_breaker |
      state: :half_open,
      success_count: 0
    }
    
    emit_state_change_telemetry(circuit_breaker.name, circuit_breaker.state, :half_open)
    
    new_circuit_breaker
  end

  defp transition_to_closed(circuit_breaker) do
    new_circuit_breaker = %{circuit_breaker |
      state: :closed,
      failure_count: 0,
      success_count: 0
    }
    
    emit_state_change_telemetry(circuit_breaker.name, circuit_breaker.state, :closed)
    
    new_circuit_breaker
  end

  defp emit_telemetry(name, result, duration \\ nil) do
    measurements = case duration do
      nil -> %{}
      duration -> %{duration: duration}
    end
    
    :telemetry.execute(
      [:vsm_connections, :circuit_breaker, :call],
      measurements,
      %{name: name, result: result}
    )
  end

  defp emit_state_change_telemetry(name, from_state, to_state, reason \\ nil) do
    metadata = %{name: name, from_state: from_state, to_state: to_state}
    metadata = if reason, do: Map.put(metadata, :reason, reason), else: metadata
    
    :telemetry.execute(
      [:vsm_connections, :circuit_breaker, :state_change],
      %{timestamp: System.system_time(:millisecond)},
      metadata
    )
  end
end