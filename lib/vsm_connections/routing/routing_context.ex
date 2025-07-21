defmodule VsmConnections.Routing.RoutingContext do
  @moduledoc """
  Context information for message routing decisions.
  """
  
  defstruct [
    :message,
    :metadata,
    :channel_type,
    :sender_connection,
    :target_connection,
    :routing_rules,
    :timestamp,
    :correlation_id,
    :trace_id,
    :opts,
    :source
  ]
  
  @type t :: %__MODULE__{
    message: any(),
    metadata: map(),
    channel_type: atom(),
    sender_connection: term(),
    target_connection: term() | nil,
    routing_rules: list(),
    timestamp: DateTime.t(),
    correlation_id: String.t() | nil,
    trace_id: String.t() | nil,
    opts: keyword() | nil,
    source: String.t() | nil
  }
end