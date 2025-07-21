defmodule VsmConnectionsTest do
  use ExUnit.Case
  doctest VsmConnections

  test "greets the world" do
    assert VsmConnections.hello() == :world
  end
end
