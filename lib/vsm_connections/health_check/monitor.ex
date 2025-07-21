defmodule VsmConnections.HealthCheck.Monitor do
  @moduledoc """
  Health check monitor for services.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    {:ok, opts}
  end
end