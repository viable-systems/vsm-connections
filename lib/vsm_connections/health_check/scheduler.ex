defmodule VsmConnections.HealthCheck.Scheduler do
  @moduledoc """
  Scheduler for periodic health checks.
  """

  use GenServer

  def start_link(service_name, interval, callback) do
    GenServer.start_link(__MODULE__, {service_name, interval, callback})
  end

  @impl true
  def init({service_name, interval, callback}) do
    schedule_check(interval)
    {:ok, %{service_name: service_name, interval: interval, callback: callback}}
  end

  @impl true
  def handle_info(:check, state) do
    state.callback.()
    schedule_check(state.interval)
    {:noreply, state}
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check, interval)
  end
end