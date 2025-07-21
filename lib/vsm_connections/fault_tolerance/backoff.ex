defmodule VsmConnections.FaultTolerance.Backoff do
  @moduledoc """
  Backoff calculation utilities.
  """

  def calculate_delay(attempt, options) do
    base_delay = Map.get(options, :base_delay, 100)
    max_delay = Map.get(options, :max_delay, 5_000)
    jitter = Map.get(options, :jitter, true)
    strategy = Map.get(options, :backoff_strategy, :exponential)

    delay = case strategy do
      :exponential -> base_delay * :math.pow(2, attempt - 1)
      :linear -> base_delay * attempt
      :constant -> base_delay
    end

    delay = min(delay, max_delay)

    if jitter do
      jitter_amount = delay * 0.1 * :rand.uniform()
      round(delay + jitter_amount)
    else
      round(delay)
    end
  end
end