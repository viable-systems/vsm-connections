defmodule VsmConnections.Adapters.AdapterBehaviour do
  @moduledoc """
  Defines the common behavior that all protocol adapters must implement.
  
  This ensures consistent interfaces across different protocols while allowing
  protocol-specific optimizations and features.
  """

  @type connection :: term()
  @type message :: term()
  @type opts :: keyword()
  @type error :: {:error, term()}
  @type metadata :: map()

  @doc """
  Establishes a connection to the external system.
  
  ## Options
  
  Common options across all adapters:
  - `:timeout` - Connection timeout in milliseconds
  - `:pool_name` - Name of the connection pool to use
  - `:circuit_breaker` - Circuit breaker configuration
  
  Protocol-specific options vary by adapter.
  """
  @callback connect(opts) :: {:ok, connection} | error

  @doc """
  Sends a message through the connection.
  
  The message format depends on the specific protocol adapter.
  """
  @callback send(connection, message) :: {:ok, term()} | error

  @doc """
  Receives a message from the connection.
  
  ## Options
  - `:timeout` - Receive timeout in milliseconds (default: 5000)
  """
  @callback receive(connection, opts) :: {:ok, message} | error

  @doc """
  Gracefully closes the connection.
  """
  @callback disconnect(connection) :: :ok | error

  @doc """
  Transforms an external message format to VSM internal format.
  
  This includes:
  - Schema validation
  - Data normalization
  - Metadata extraction
  - VSM routing information
  """
  @callback transform_inbound(message, metadata) :: {:ok, vsm_message :: map()} | error

  @doc """
  Transforms a VSM message to external format.
  
  This includes:
  - Protocol-specific formatting
  - Header generation
  - Encoding selection
  - Compliance checks
  """
  @callback transform_outbound(vsm_message :: map(), metadata) :: {:ok, message} | error

  @doc """
  Returns the health status of the adapter.
  
  Used for monitoring and circuit breaker decisions.
  """
  @callback health_check(connection) :: :healthy | :unhealthy | :degraded

  @doc """
  Returns adapter-specific metrics.
  
  Common metrics include:
  - Connection count
  - Message throughput
  - Error rates
  - Latency percentiles
  """
  @callback get_metrics() :: map()

  @doc """
  Validates adapter configuration.
  
  Called during adapter initialization and configuration updates.
  """
  @callback validate_config(config :: map()) :: :ok | error

  @doc """
  Returns the adapter's capabilities.
  
  Used by the router to determine optimal message handling.
  """
  @callback capabilities() :: %{
    streaming: boolean(),
    bidirectional: boolean(),
    ordered_delivery: boolean(),
    reliable_delivery: boolean(),
    max_message_size: integer() | :unlimited
  }

  @doc """
  Handles protocol-specific errors and maps them to VSM error categories.
  """
  @callback handle_error(error :: term()) :: {:recoverable | :permanent | :timeout, reason :: term()}

  @doc """
  Optional callback for adapters that support streaming.
  
  Creates a stream for continuous message flow.
  """
  @callback stream(connection, stream_opts :: keyword()) :: {:ok, Stream.t()} | error
  @optional_callbacks stream: 2

  @doc """
  Optional callback for adapters that support subscriptions.
  
  Subscribes to a topic/channel/queue for message delivery.
  """
  @callback subscribe(connection, topic :: String.t(), handler :: function()) :: {:ok, subscription_ref :: term()} | error
  @optional_callbacks subscribe: 3

  @doc """
  Optional callback for subscription cleanup.
  """
  @callback unsubscribe(connection, subscription_ref :: term()) :: :ok | error
  @optional_callbacks unsubscribe: 2
end