defmodule VsmConnections.HealthCheck do
  @moduledoc """
  Health checking system for VSM Connections.
  
  This module provides comprehensive health monitoring for:
  - Connection pools
  - External services
  - Circuit breakers
  - Redis connections
  - Protocol adapters
  
  ## Features
  
  - Configurable health check intervals
  - Multiple health check strategies
  - Automatic service discovery
  - Health status aggregation
  - Integration with VSM telemetry
  - Threshold-based alerting
  """

  use GenServer

  alias VsmConnections.Config
  alias VsmConnections.HealthCheck.{Monitor, Scheduler}

  defstruct [
    :name,
    :config,
    :status,
    :last_check,
    :failure_count,
    :success_count,
    :total_checks,
    :average_response_time,
    :last_error
  ]

  @type health_status :: :healthy | :unhealthy | :unknown
  @type service_name :: atom()

  @doc """
  Starts the health check system.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Performs a health check for a specific service.
  
  ## Examples
  
      :ok = VsmConnections.HealthCheck.check(:api_service)
      {:error, :timeout} = VsmConnections.HealthCheck.check(:slow_service)
  """
  @spec check(service_name()) :: :ok | {:error, term()}
  def check(service_name) do
    GenServer.call(__MODULE__, {:check, service_name})
  end

  @doc """
  Gets the current health status of a service.
  
  ## Examples
  
      :healthy = VsmConnections.HealthCheck.get_status(:api_service)
      :unhealthy = VsmConnections.HealthCheck.get_status(:broken_service)
  """
  @spec get_status(service_name()) :: health_status()
  def get_status(service_name) do
    GenServer.call(__MODULE__, {:get_status, service_name})
  end

  @doc """
  Gets the health status of all monitored services.
  
  ## Examples
  
      %{
        api_service: :healthy,
        database: :unhealthy,
        cache: :healthy
      } = VsmConnections.HealthCheck.get_all_status()
  """
  @spec get_all_status() :: %{service_name() => health_status()}
  def get_all_status do
    GenServer.call(__MODULE__, :get_all_status)
  end

  @doc """
  Gets detailed health statistics for a service.
  
  ## Examples
  
      %{
        status: :healthy,
        failure_count: 0,
        success_count: 100,
        total_checks: 100,
        average_response_time: 250,
        last_check: ~U[2024-01-01 12:00:00Z]
      } = VsmConnections.HealthCheck.get_stats(:api_service)
  """
  @spec get_stats(service_name()) :: map() | nil
  def get_stats(service_name) do
    GenServer.call(__MODULE__, {:get_stats, service_name})
  end

  @doc """
  Registers a new service for health monitoring.
  
  ## Options
  
  - `:url` - Health check endpoint URL
  - `:interval` - Check interval in milliseconds
  - `:timeout` - Health check timeout
  - `:method` - HTTP method (:get, :post, :head)
  - `:headers` - Additional headers
  - `:expected_status` - Expected HTTP status codes
  - `:custom_check` - Custom health check function
  
  ## Examples
  
      :ok = VsmConnections.HealthCheck.register_service(:api_service, %{
        url: "https://api.example.com/health",
        interval: 30_000,
        timeout: 5_000,
        expected_status: [200, 204]
      })
  """
  @spec register_service(service_name(), map()) :: :ok | {:error, term()}
  def register_service(service_name, config) do
    GenServer.call(__MODULE__, {:register_service, service_name, config})
  end

  @doc """
  Unregisters a service from health monitoring.
  
  ## Examples
  
      :ok = VsmConnections.HealthCheck.unregister_service(:old_service)
  """
  @spec unregister_service(service_name()) :: :ok
  def unregister_service(service_name) do
    GenServer.call(__MODULE__, {:unregister_service, service_name})
  end

  @doc """
  Forces a health check for all services.
  
  ## Examples
  
      :ok = VsmConnections.HealthCheck.check_all()
  """
  @spec check_all() :: :ok
  def check_all do
    GenServer.cast(__MODULE__, :check_all)
  end

  @doc """
  Gets the overall system health status.
  
  Returns :healthy only if all services are healthy.
  
  ## Examples
  
      :healthy = VsmConnections.HealthCheck.overall_status()
      :unhealthy = VsmConnections.HealthCheck.overall_status()
  """
  @spec overall_status() :: health_status()
  def overall_status do
    GenServer.call(__MODULE__, :overall_status)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    state = %{
      services: %{},
      schedulers: %{}
    }
    
    # Register default services from config
    register_default_services(state)
    
    {:ok, state}
  end

  @impl true
  def handle_call({:check, service_name}, _from, state) do
    case Map.get(state.services, service_name) do
      nil ->
        {:reply, {:error, :service_not_found}, state}
      
      service ->
        {result, updated_service} = perform_health_check(service)
        new_state = %{state | services: Map.put(state.services, service_name, updated_service)}
        {:reply, result, new_state}
    end
  end

  def handle_call({:get_status, service_name}, _from, state) do
    status = case Map.get(state.services, service_name) do
      nil -> :unknown
      service -> service.status
    end
    
    {:reply, status, state}
  end

  def handle_call(:get_all_status, _from, state) do
    status_map = 
      state.services
      |> Enum.map(fn {name, service} -> {name, service.status} end)
      |> Enum.into(%{})
    
    {:reply, status_map, state}
  end

  def handle_call({:get_stats, service_name}, _from, state) do
    stats = case Map.get(state.services, service_name) do
      nil -> nil
      service -> service_to_stats(service)
    end
    
    {:reply, stats, state}
  end

  def handle_call({:register_service, service_name, config}, _from, state) do
    case validate_service_config(config) do
      :ok ->
        service = create_service(service_name, config)
        scheduler_pid = start_scheduler(service_name, config)
        
        new_state = %{state |
          services: Map.put(state.services, service_name, service),
          schedulers: Map.put(state.schedulers, service_name, scheduler_pid)
        }
        
        {:reply, :ok, new_state}
      
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister_service, service_name}, _from, state) do
    # Stop scheduler if exists
    case Map.get(state.schedulers, service_name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
    
    new_state = %{state |
      services: Map.delete(state.services, service_name),
      schedulers: Map.delete(state.schedulers, service_name)
    }
    
    {:reply, :ok, new_state}
  end

  def handle_call(:overall_status, _from, state) do
    overall = 
      state.services
      |> Map.values()
      |> Enum.map(& &1.status)
      |> calculate_overall_status()
    
    {:reply, overall, state}
  end

  @impl true
  def handle_cast(:check_all, state) do
    new_services = 
      state.services
      |> Enum.map(fn {name, service} ->
        {_result, updated_service} = perform_health_check(service)
        {name, updated_service}
      end)
      |> Enum.into(%{})
    
    new_state = %{state | services: new_services}
    {:noreply, new_state}
  end

  def handle_cast({:scheduled_check, service_name}, state) do
    case Map.get(state.services, service_name) do
      nil ->
        {:noreply, state}
      
      service ->
        {_result, updated_service} = perform_health_check(service)
        new_state = %{state | services: Map.put(state.services, service_name, updated_service)}
        {:noreply, new_state}
    end
  end

  # Private functions

  defp register_default_services(state) do
    # Register health checks from configuration
    health_checks = Config.get(:health_checks, %{})
    
    Enum.each(health_checks, fn {service_name, config} ->
      if config[:enabled] != false do
        GenServer.call(self(), {:register_service, service_name, config})
      end
    end)
    
    state
  end

  defp validate_service_config(config) do
    cond do
      config[:url] && is_binary(config[:url]) -> :ok
      config[:custom_check] && is_function(config[:custom_check], 0) -> :ok
      true -> {:error, :invalid_config}
    end
  end

  defp create_service(name, config) do
    %__MODULE__{
      name: name,
      config: config,
      status: :unknown,
      last_check: nil,
      failure_count: 0,
      success_count: 0,
      total_checks: 0,
      average_response_time: 0.0,
      last_error: nil
    }
  end

  defp start_scheduler(service_name, config) do
    interval = Map.get(config, :interval, 30_000)
    
    {:ok, pid} = Scheduler.start_link(service_name, interval, fn ->
      GenServer.cast(__MODULE__, {:scheduled_check, service_name})
    end)
    
    pid
  end

  defp perform_health_check(service) do
    start_time = System.monotonic_time()
    
    result = case service.config do
      %{custom_check: check_fun} when is_function(check_fun, 0) ->
        execute_custom_check(check_fun)
      
      %{url: url} ->
        execute_http_check(service.config)
      
      _ ->
        {:error, :invalid_config}
    end
    
    end_time = System.monotonic_time()
    response_time = System.convert_time_unit(end_time - start_time, :native, :millisecond)
    
    updated_service = update_service_stats(service, result, response_time)
    emit_health_check_telemetry(service.name, result, response_time)
    
    {result, updated_service}
  end

  defp execute_custom_check(check_fun) do
    try do
      check_fun.()
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp execute_http_check(config) do
    url = config[:url]
    method = config[:method] || :get
    timeout = config[:timeout] || 5_000
    headers = config[:headers] || []
    expected_status = config[:expected_status] || [200]
    
    case VsmConnections.Adapters.HTTP.request(
           method: method,
           url: url,
           headers: headers,
           timeout: timeout
         ) do
      {:ok, %{status: status}} ->
        if status in expected_status do
          :ok
        else
          {:error, {:unexpected_status, status}}
        end
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_service_stats(service, result, response_time) do
    new_total = service.total_checks + 1
    
    {new_status, new_success, new_failure, new_error} = case result do
      :ok ->
        {:healthy, service.success_count + 1, service.failure_count, nil}
      
      {:error, reason} ->
        {:unhealthy, service.success_count, service.failure_count + 1, reason}
    end
    
    # Update average response time using exponential moving average
    alpha = 0.1  # Smoothing factor
    new_avg_response_time = case service.average_response_time do
      0.0 -> response_time
      avg -> alpha * response_time + (1 - alpha) * avg
    end
    
    %{service |
      status: new_status,
      last_check: DateTime.utc_now(),
      success_count: new_success,
      failure_count: new_failure,
      total_checks: new_total,
      average_response_time: new_avg_response_time,
      last_error: new_error
    }
  end

  defp calculate_overall_status(statuses) do
    cond do
      Enum.empty?(statuses) -> :unknown
      Enum.all?(statuses, &(&1 == :healthy)) -> :healthy
      true -> :unhealthy
    end
  end

  defp service_to_stats(service) do
    %{
      name: service.name,
      status: service.status,
      last_check: service.last_check,
      failure_count: service.failure_count,
      success_count: service.success_count,
      total_checks: service.total_checks,
      average_response_time: service.average_response_time,
      last_error: service.last_error,
      success_rate: calculate_success_rate(service)
    }
  end

  defp calculate_success_rate(service) do
    if service.total_checks > 0 do
      service.success_count / service.total_checks * 100.0
    else
      0.0
    end
  end

  defp emit_health_check_telemetry(service_name, result, response_time) do
    status = case result do
      :ok -> :success
      {:error, _} -> :failure
    end
    
    :telemetry.execute(
      [:vsm_connections, :health_check, :result],
      %{response_time: response_time},
      %{service: service_name, result: status}
    )
  end
end