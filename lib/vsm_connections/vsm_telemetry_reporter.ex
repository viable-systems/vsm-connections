defmodule VsmConnections.VSMTelemetryReporter do
  @moduledoc """
  VSM Telemetry reporter for integration with VSM Core.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Attach to VSM Connections telemetry events
    events = [
      [:vsm_connections, :pool, :checkout],
      [:vsm_connections, :circuit_breaker, :call],
      [:vsm_connections, :health_check, :result],
      [:vsm_connections, :adapter, :request],
      [:vsm_connections, :redis, :command]
    ]

    :telemetry.attach_many("vsm-connections-reporter", events, &handle_event/4, nil)

    {:ok, %{}}
  end

  def handle_event(event, measurements, metadata, _config) do
    # Forward telemetry to VSM Core if available
    # For now, just log the events
    :ok
  end
end