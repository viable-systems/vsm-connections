defmodule VsmConnections.Redis.Supervisor do
  @moduledoc """
  Supervisor for Redis components.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      VsmConnections.Redis.Pool
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end