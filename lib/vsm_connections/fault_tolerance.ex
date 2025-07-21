defmodule VsmConnections.FaultTolerance do
  @moduledoc """
  Fault tolerance mechanisms for VSM Connections.
  
  This module provides comprehensive fault tolerance including:
  - Retry logic with exponential backoff
  - Jitter to prevent thundering herd
  - Circuit breaker integration
  - Deadline/timeout management
  - Error classification and handling
  - Telemetry and monitoring
  """

  alias VsmConnections.FaultTolerance.{Retry, Backoff, Scheduler}

  @default_retry_options %{
    max_attempts: 3,
    base_delay: 100,
    max_delay: 5_000,
    jitter: true,
    backoff_strategy: :exponential,
    retryable_errors: [:timeout, :connection_refused, :network_error]
  }

  @doc """
  Executes a function with retry logic and exponential backoff.
  
  ## Options
  
  - `:max_attempts` - Maximum retry attempts (default: 3)
  - `:base_delay` - Base delay in milliseconds (default: 100)
  - `:max_delay` - Maximum delay in milliseconds (default: 5000)
  - `:jitter` - Add random jitter to delays (default: true)
  - `:backoff_strategy` - :exponential, :linear, or :constant (default: :exponential)
  - `:retryable_errors` - List of retryable error types
  - `:on_retry` - Callback function called on each retry
  
  ## Examples
  
      {:ok, result} = VsmConnections.FaultTolerance.with_retry(fn ->
        risky_operation()
      end, max_attempts: 5, base_delay: 200)
      
      # With custom error handling
      {:ok, result} = VsmConnections.FaultTolerance.with_retry(fn ->
        api_call()
      end, 
        max_attempts: 3,
        retryable_errors: [:timeout, :service_unavailable],
        on_retry: fn attempt, error ->
          Logger.warn("Retry attempt #{attempt}: #{inspect(error)}")
        end
      )
  """
  @spec with_retry(function(), keyword()) :: {:ok, term()} | {:error, term()}
  def with_retry(fun, opts \\ []) when is_function(fun, 0) do
    options = merge_retry_options(opts)
    
    start_time = System.monotonic_time()
    result = execute_with_retry(fun, options, 1)
    end_time = System.monotonic_time()
    
    emit_retry_telemetry(result, options, start_time, end_time)
    result
  end

  @doc """
  Executes a function with a deadline (timeout).
  
  ## Examples
  
      {:ok, result} = VsmConnections.FaultTolerance.with_deadline(fn ->
        slow_operation()
      end, 5_000)
      
      {:error, :timeout} = VsmConnections.FaultTolerance.with_deadline(fn ->
        very_slow_operation()
      end, 1_000)
  """
  @spec with_deadline(function(), pos_integer()) :: {:ok, term()} | {:error, :timeout}
  def with_deadline(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) do
    start_time = System.monotonic_time()
    
    task = Task.async(fun)
    
    result = case Task.yield(task, timeout_ms) do
      {:ok, result} -> 
        {:ok, result}
      
      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
    
    end_time = System.monotonic_time()
    emit_deadline_telemetry(result, timeout_ms, start_time, end_time)
    
    result
  end

  @doc """
  Combines retry logic with deadline management.
  
  ## Examples
  
      {:ok, result} = VsmConnections.FaultTolerance.with_retry_and_deadline(fn ->
        api_call()
      end, 
        max_attempts: 3,
        base_delay: 100,
        deadline: 10_000
      )
  """
  @spec with_retry_and_deadline(function(), keyword()) :: {:ok, term()} | {:error, term()}
  def with_retry_and_deadline(fun, opts \\ []) when is_function(fun, 0) do
    deadline = Keyword.get(opts, :deadline, 30_000)
    retry_opts = Keyword.delete(opts, :deadline)
    
    with_deadline(fn ->
      with_retry(fun, retry_opts)
    end, deadline)
  end

  @doc """
  Creates a retry scheduler for periodic operations.
  
  ## Examples
  
      {:ok, scheduler} = VsmConnections.FaultTolerance.create_scheduler(
        name: :health_checker,
        function: &check_health/0,
        interval: 30_000,
        retry_options: [max_attempts: 2]
      )
  """
  @spec create_scheduler(keyword()) :: {:ok, pid()} | {:error, term()}
  def create_scheduler(opts) do
    name = Keyword.fetch!(opts, :name)
    function = Keyword.fetch!(opts, :function)
    interval = Keyword.fetch!(opts, :interval)
    retry_options = Keyword.get(opts, :retry_options, [])
    
    Scheduler.start_link(name, function, interval, retry_options)
  end

  @doc """
  Calculates the next delay using the configured backoff strategy.
  
  ## Examples
  
      250 = VsmConnections.FaultTolerance.calculate_delay(2, %{
        base_delay: 100,
        backoff_strategy: :exponential,
        jitter: false
      })
  """
  @spec calculate_delay(pos_integer(), map()) :: pos_integer()
  def calculate_delay(attempt, options) do
    Backoff.calculate_delay(attempt, options)
  end

  @doc """
  Checks if an error is retryable based on the configuration.
  
  ## Examples
  
      true = VsmConnections.FaultTolerance.retryable_error?(:timeout, [:timeout, :network_error])
      false = VsmConnections.FaultTolerance.retryable_error?(:invalid_request, [:timeout])
  """
  @spec retryable_error?(term(), [atom()]) :: boolean()
  def retryable_error?(error, retryable_errors) do
    Retry.retryable_error?(error, retryable_errors)
  end

  @doc """
  Gets statistics for retry operations.
  
  ## Examples
  
      %{
        total_operations: 1000,
        successful_first_attempt: 850,
        retried_operations: 150,
        failed_operations: 25,
        average_attempts: 1.2
      } = VsmConnections.FaultTolerance.get_stats()
  """
  @spec get_stats() :: map()
  def get_stats do
    # This would typically be stored in ETS or a GenServer
    # For now, return empty stats
    %{
      total_operations: 0,
      successful_first_attempt: 0,
      retried_operations: 0,
      failed_operations: 0,
      average_attempts: 0.0
    }
  end

  # Private functions

  defp merge_retry_options(opts) do
    @default_retry_options
    |> Map.merge(Enum.into(opts, %{}))
  end

  defp execute_with_retry(fun, options, attempt) do
    try do
      result = fun.()
      emit_attempt_telemetry(:success, attempt, options)
      {:ok, result}
    rescue
      error ->
        handle_retry_error({:error, error}, options, attempt)
    catch
      :exit, reason ->
        handle_retry_error({:error, {:exit, reason}}, options, attempt)
      
      :throw, value ->
        handle_retry_error({:error, {:throw, value}}, options, attempt)
      
      kind, reason ->
        handle_retry_error({:error, {kind, reason}}, options, attempt)
    end
  end

  defp handle_retry_error({:error, error}, options, attempt) do
    emit_attempt_telemetry(:error, attempt, options, error)
    
    cond do
      attempt >= options.max_attempts ->
        emit_final_failure_telemetry(error, attempt, options)
        {:error, error}
      
      not retryable_error?(error, options.retryable_errors) ->
        emit_non_retryable_telemetry(error, attempt, options)
        {:error, error}
      
      true ->
        delay = calculate_delay(attempt, options)
        call_retry_callback(options, attempt, error)
        
        :timer.sleep(delay)
        execute_with_retry(options.function || fun, options, attempt + 1)
    end
  end

  defp call_retry_callback(options, attempt, error) do
    case Map.get(options, :on_retry) do
      nil -> :ok
      callback when is_function(callback, 2) -> callback.(attempt, error)
      _ -> :ok
    end
  end

  defp emit_retry_telemetry(result, options, start_time, end_time) do
    duration = end_time - start_time
    status = case result do
      {:ok, _} -> :success
      {:error, _} -> :error
    end
    
    :telemetry.execute(
      [:vsm_connections, :fault_tolerance, :retry],
      %{duration: duration},
      %{
        result: status,
        max_attempts: options.max_attempts,
        backoff_strategy: options.backoff_strategy
      }
    )
  end

  defp emit_attempt_telemetry(result, attempt, options, error \\ nil) do
    metadata = %{
      attempt: attempt,
      result: result,
      max_attempts: options.max_attempts
    }
    
    metadata = if error, do: Map.put(metadata, :error, error), else: metadata
    
    :telemetry.execute(
      [:vsm_connections, :fault_tolerance, :attempt],
      %{},
      metadata
    )
  end

  defp emit_deadline_telemetry(result, timeout_ms, start_time, end_time) do
    duration = end_time - start_time
    status = case result do
      {:ok, _} -> :success
      {:error, :timeout} -> :timeout
      {:error, _} -> :error
    end
    
    :telemetry.execute(
      [:vsm_connections, :fault_tolerance, :deadline],
      %{duration: duration, timeout: timeout_ms},
      %{result: status}
    )
  end

  defp emit_final_failure_telemetry(error, attempts, options) do
    :telemetry.execute(
      [:vsm_connections, :fault_tolerance, :final_failure],
      %{attempts: attempts},
      %{
        error: error,
        max_attempts: options.max_attempts,
        backoff_strategy: options.backoff_strategy
      }
    )
  end

  defp emit_non_retryable_telemetry(error, attempt, options) do
    :telemetry.execute(
      [:vsm_connections, :fault_tolerance, :non_retryable],
      %{},
      %{
        error: error,
        attempt: attempt,
        retryable_errors: options.retryable_errors
      }
    )
  end
end