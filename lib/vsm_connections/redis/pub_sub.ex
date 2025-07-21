defmodule VsmConnections.Redis.PubSub do
  @moduledoc """
  Redis Pub/Sub functionality.
  """

  def subscribe(channels, callback) when is_list(channels) do
    # Mock implementation
    {:ok, spawn(fn -> 
      callback.(%{channel: List.first(channels), message: "test"}) 
    end)}
  end

  def subscribe(channel, callback) when is_binary(channel) do
    subscribe([channel], callback)
  end

  def psubscribe(patterns, callback) when is_list(patterns) do
    # Mock implementation  
    {:ok, spawn(fn -> 
      callback.(%{pattern: List.first(patterns), message: "test"}) 
    end)}
  end

  def psubscribe(pattern, callback) when is_binary(pattern) do
    psubscribe([pattern], callback)
  end
end