defmodule VsmConnections.Pool.Manager do
  @moduledoc """
  Pool manager for VSM Connections.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{pools: %{}}}
  end

  def create_pool(name, config) do
    GenServer.call(__MODULE__, {:create_pool, name, config})
  end

  def remove_pool(name) do
    GenServer.call(__MODULE__, {:remove_pool, name})
  end

  def update_pool(name, config) do
    GenServer.call(__MODULE__, {:update_pool, name, config})
  end

  def get_pool_config(name) do
    GenServer.call(__MODULE__, {:get_pool_config, name})
  end

  def list_pools do
    GenServer.call(__MODULE__, :list_pools)
  end

  def get_finch_pool(name) do
    GenServer.call(__MODULE__, {:get_finch_pool, name})
  end

  @impl true
  def handle_call({:create_pool, name, config}, _from, state) do
    new_pools = Map.put(state.pools, name, config)
    {:reply, :ok, %{state | pools: new_pools}}
  end

  def handle_call({:remove_pool, name}, _from, state) do
    new_pools = Map.delete(state.pools, name)
    {:reply, :ok, %{state | pools: new_pools}}
  end

  def handle_call({:update_pool, name, config}, _from, state) do
    case Map.get(state.pools, name) do
      nil -> {:reply, {:error, :not_found}, state}
      _existing -> 
        new_pools = Map.put(state.pools, name, config)
        {:reply, :ok, %{state | pools: new_pools}}
    end
  end

  def handle_call({:get_pool_config, name}, _from, state) do
    config = Map.get(state.pools, name)
    {:reply, config, state}
  end

  def handle_call(:list_pools, _from, state) do
    pools = Map.keys(state.pools)
    {:reply, pools, state}
  end

  def handle_call({:get_finch_pool, name}, _from, state) do
    case Map.get(state.pools, name) do
      %{protocol: protocol} when protocol in [:http, :https] ->
        {:reply, {:ok, VsmConnections.Finch}, state}
      _ ->
        {:reply, {:error, :not_finch_pool}, state}
    end
  end
end