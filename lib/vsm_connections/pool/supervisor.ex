defmodule VsmConnections.Pool.Supervisor do
  @moduledoc """
  Supervisor for connection pools.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      VsmConnections.Pool.Manager
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end