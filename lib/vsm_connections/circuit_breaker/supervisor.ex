defmodule VsmConnections.CircuitBreaker.Supervisor do
  @moduledoc """
  Supervisor for circuit breakers.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Create registry for circuit breakers
    Registry.start_link(keys: :unique, name: VsmConnections.CircuitBreaker.Registry)
    
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_circuit_breaker(name, config) do
    spec = {VsmConnections.CircuitBreaker, {name, config}}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_circuit_breaker(name) do
    case Registry.lookup(VsmConnections.CircuitBreaker.Registry, name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] ->
        {:error, :not_found}
    end
  end

  def list_circuit_breakers do
    Registry.select(VsmConnections.CircuitBreaker.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end