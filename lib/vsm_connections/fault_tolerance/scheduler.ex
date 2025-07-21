defmodule VsmConnections.FaultTolerance.Scheduler do
  @moduledoc """
  Scheduler for fault tolerance operations.
  """

  use GenServer

  def start_link(name, function, interval, retry_options) do
    GenServer.start_link(__MODULE__, {name, function, interval, retry_options})
  end

  @impl true
  def init({name, function, interval, retry_options}) do
    schedule_execution(interval)
    {:ok, %{name: name, function: function, interval: interval, retry_options: retry_options}}
  end

  @impl true
  def handle_info(:execute, state) do
    VsmConnections.FaultTolerance.with_retry(state.function, state.retry_options)
    schedule_execution(state.interval)
    {:noreply, state}
  end

  defp schedule_execution(interval) do
    Process.send_after(self(), :execute, interval)
  end
end