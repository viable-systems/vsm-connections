defmodule VsmConnections.Pool.Worker do
  @moduledoc """
  Generic pool worker for non-HTTP protocols.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  def health_check(worker) do
    GenServer.call(worker, :health_check)
  end

  @impl true
  def handle_call(:health_check, _from, state) do
    # Basic health check - could be extended per protocol
    {:reply, :ok, state}
  end
end