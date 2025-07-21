defmodule VsmConnections.CircuitBreaker.Config do
  @moduledoc """
  Configuration structure for circuit breakers.
  """

  defstruct [
    :failure_threshold,
    :recovery_timeout,
    :call_timeout,
    :success_threshold,
    :monitor_rejection_period
  ]

  @default_config %{
    failure_threshold: 5,
    recovery_timeout: 60_000,
    call_timeout: 5_000,
    success_threshold: 3,
    monitor_rejection_period: 1_000
  }

  @doc """
  Creates a new circuit breaker configuration.
  """
  def new(config) when is_map(config) do
    merged_config = Map.merge(@default_config, config)
    
    %__MODULE__{
      failure_threshold: merged_config.failure_threshold,
      recovery_timeout: merged_config.recovery_timeout,
      call_timeout: merged_config.call_timeout,
      success_threshold: merged_config.success_threshold,
      monitor_rejection_period: merged_config.monitor_rejection_period
    }
  end

  def new(config) when is_list(config) do
    config
    |> Enum.into(%{})
    |> new()
  end
end