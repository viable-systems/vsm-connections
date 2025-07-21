defmodule VsmConnections.FaultTolerance.Retry do
  @moduledoc """
  Retry logic utilities.
  """

  def retryable_error?(error, retryable_errors) do
    error in retryable_errors
  end
end