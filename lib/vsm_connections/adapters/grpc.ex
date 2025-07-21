defmodule VsmConnections.Adapters.GRPC do
  @moduledoc """
  gRPC adapter for VSM Connections.
  
  This adapter provides gRPC connectivity with:
  - Connection pooling for gRPC channels
  - Automatic retries with configurable backoff
  - Streaming support (unary, server streaming, client streaming, bidirectional)
  - Circuit breaker integration
  - Comprehensive error handling
  - Deadline/timeout management
  """

  alias VsmConnections.Config
  alias VsmConnections.FaultTolerance
  alias GRPC.Channel

  @default_options %{
    timeout: 5_000,
    max_receive_message_length: 4 * 1024 * 1024,  # 4MB
    max_send_message_length: 4 * 1024 * 1024,     # 4MB
    keepalive_time: 30_000,
    keepalive_timeout: 5_000,
    http2_initial_conn_window_size: 1024 * 1024,  # 1MB
    http2_initial_window_size: 1024 * 1024        # 1MB
  }

  @doc """
  Creates a gRPC channel/connection.
  
  ## Options
  
  - `:host` - gRPC server host
  - `:port` - gRPC server port
  - `:scheme` - :http or :https (default: :https)
  - `:credentials` - TLS credentials
  - `:timeout` - Default timeout for calls
  - `:headers` - Default headers
  - `:interceptors` - gRPC interceptors
  
  ## Examples
  
      {:ok, channel} = VsmConnections.Adapters.GRPC.connect(
        host: "api.example.com",
        port: 443,
        scheme: :https
      )
  """
  @spec connect(keyword()) :: {:ok, Channel.t()} | {:error, term()}
  def connect(opts) do
    start_time = System.monotonic_time()
    
    with {:ok, channel_opts} <- build_channel_options(opts),
         {:ok, channel} <- create_channel(channel_opts) do
      
      end_time = System.monotonic_time()
      emit_telemetry(:connect, :success, opts, start_time, end_time)
      
      {:ok, channel}
    else
      {:error, reason} ->
        end_time = System.monotonic_time()
        emit_telemetry(:connect, :error, opts, start_time, end_time, reason)
        {:error, reason}
    end
  end

  @doc """
  Makes a unary gRPC call.
  
  ## Examples
  
      {:ok, response} = VsmConnections.Adapters.GRPC.call(
        service: MyService.Stub,
        method: :get_user,
        message: %GetUserRequest{id: 123},
        channel: channel
      )
  """
  @spec call(keyword()) :: {:ok, term()} | {:error, term()}
  def call(opts) do
    start_time = System.monotonic_time()
    
    with {:ok, call_opts} <- build_call_options(opts),
         {:ok, response} <- execute_call(call_opts) do
      
      end_time = System.monotonic_time()
      emit_telemetry(:call, :success, opts, start_time, end_time)
      
      {:ok, response}
    else
      {:error, reason} ->
        end_time = System.monotonic_time()
        emit_telemetry(:call, :error, opts, start_time, end_time, reason)
        {:error, reason}
    end
  end

  @doc """
  Starts a server streaming call.
  
  ## Examples
  
      {:ok, stream} = VsmConnections.Adapters.GRPC.server_stream(
        service: MyService.Stub,
        method: :list_users,
        message: %ListUsersRequest{},
        channel: channel
      )
      
      Enum.each(stream, fn {:ok, user} ->
        IO.inspect(user)
      end)
  """
  @spec server_stream(keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def server_stream(opts) do
    start_time = System.monotonic_time()
    
    with {:ok, call_opts} <- build_call_options(opts),
         {:ok, stream} <- execute_server_stream(call_opts) do
      
      end_time = System.monotonic_time()
      emit_telemetry(:server_stream, :success, opts, start_time, end_time)
      
      {:ok, stream}
    else
      {:error, reason} ->
        end_time = System.monotonic_time()
        emit_telemetry(:server_stream, :error, opts, start_time, end_time, reason)
        {:error, reason}
    end
  end

  @doc """
  Starts a client streaming call.
  
  ## Examples
  
      {:ok, stream} = VsmConnections.Adapters.GRPC.client_stream(
        service: MyService.Stub,
        method: :create_users,
        channel: channel
      )
      
      GRPC.Stub.send_request(stream, %CreateUserRequest{name: "John"})
      GRPC.Stub.send_request(stream, %CreateUserRequest{name: "Jane"})
      {:ok, response} = GRPC.Stub.end_stream(stream)
  """
  @spec client_stream(keyword()) :: {:ok, GRPC.Client.Stream.t()} | {:error, term()}
  def client_stream(opts) do
    start_time = System.monotonic_time()
    
    with {:ok, call_opts} <- build_call_options(opts),
         {:ok, stream} <- execute_client_stream(call_opts) do
      
      end_time = System.monotonic_time()
      emit_telemetry(:client_stream, :success, opts, start_time, end_time)
      
      {:ok, stream}
    else
      {:error, reason} ->
        end_time = System.monotonic_time()
        emit_telemetry(:client_stream, :error, opts, start_time, end_time, reason)
        {:error, reason}
    end
  end

  @doc """
  Starts a bidirectional streaming call.
  
  ## Examples
  
      {:ok, stream} = VsmConnections.Adapters.GRPC.bidirectional_stream(
        service: MyService.Stub,
        method: :chat,
        channel: channel
      )
      
      # Send messages and receive responses asynchronously
      spawn(fn ->
        GRPC.Stub.send_request(stream, %ChatMessage{text: "Hello"})
      end)
      
      Enum.each(stream, fn {:ok, response} ->
        IO.inspect(response)
      end)
  """
  @spec bidirectional_stream(keyword()) :: {:ok, GRPC.Client.Stream.t()} | {:error, term()}
  def bidirectional_stream(opts) do
    start_time = System.monotonic_time()
    
    with {:ok, call_opts} <- build_call_options(opts),
         {:ok, stream} <- execute_bidirectional_stream(call_opts) do
      
      end_time = System.monotonic_time()
      emit_telemetry(:bidirectional_stream, :success, opts, start_time, end_time)
      
      {:ok, stream}
    else
      {:error, reason} ->
        end_time = System.monotonic_time()
        emit_telemetry(:bidirectional_stream, :error, opts, start_time, end_time, reason)
        {:error, reason}
    end
  end

  @doc """
  Closes a gRPC channel.
  
  ## Examples
  
      :ok = VsmConnections.Adapters.GRPC.disconnect(channel)
  """
  @spec disconnect(Channel.t()) :: :ok
  def disconnect(channel) do
    start_time = System.monotonic_time()
    
    result = Channel.disconnect(channel)
    
    end_time = System.monotonic_time()
    emit_telemetry(:disconnect, :success, %{}, start_time, end_time)
    
    result
  end

  @doc """
  Gets information about a gRPC channel.
  
  ## Examples
  
      %{host: "api.example.com", port: 443} = VsmConnections.Adapters.GRPC.get_channel_info(channel)
  """
  @spec get_channel_info(Channel.t()) :: map()
  def get_channel_info(channel) do
    %{
      host: channel.host,
      port: channel.port,
      scheme: channel.scheme,
      cred: channel.cred
    }
  end

  # Private functions

  defp build_channel_options(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    scheme = Keyword.get(opts, :scheme, :https)
    
    credentials = case scheme do
      :https -> build_tls_credentials(opts)
      :http -> nil
    end
    
    channel_opts = %{
      host: host,
      port: port,
      scheme: scheme,
      credentials: credentials,
      options: merge_channel_options(opts)
    }
    
    {:ok, channel_opts}
  rescue
    error -> {:error, {:build_channel_options_failed, error}}
  end

  defp build_tls_credentials(opts) do
    case Keyword.get(opts, :credentials) do
      nil ->
        # Use default TLS credentials
        :tls
      
      :insecure ->
        nil
      
      custom_creds ->
        custom_creds
    end
  end

  defp merge_channel_options(opts) do
    @default_options
    |> Map.merge(Enum.into(opts, %{}))
    |> Map.drop([:host, :port, :scheme, :credentials])
  end

  defp create_channel(channel_opts) do
    %{host: host, port: port, scheme: scheme, credentials: credentials, options: options} = channel_opts
    
    adapter_opts = [
      recv_timeout: options.timeout,
      max_receive_message_length: options.max_receive_message_length,
      max_send_message_length: options.max_send_message_length
    ]
    
    case GRPC.Stub.connect("#{host}:#{port}", 
           cred: credentials,
           adapter_opts: adapter_opts) do
      {:ok, channel} -> {:ok, channel}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_call_options(opts) do
    service = Keyword.fetch!(opts, :service)
    method = Keyword.fetch!(opts, :method)
    channel = Keyword.fetch!(opts, :channel)
    
    call_opts = %{
      service: service,
      method: method,
      channel: channel,
      message: Keyword.get(opts, :message),
      timeout: Keyword.get(opts, :timeout, @default_options.timeout),
      headers: Keyword.get(opts, :headers, []),
      retry: Keyword.get(opts, :retry, [])
    }
    
    {:ok, call_opts}
  rescue
    error -> {:error, {:build_call_options_failed, error}}
  end

  defp execute_call(call_opts) do
    %{service: service, method: method, channel: channel, message: message} = call_opts
    
    request_fun = fn ->
      service.unary_call(channel, method, message, 
        timeout: call_opts.timeout,
        headers: call_opts.headers
      )
    end
    
    case call_opts.retry do
      [] ->
        request_fun.()
      
      retry_opts when is_list(retry_opts) ->
        FaultTolerance.with_retry(request_fun, retry_opts)
    end
  end

  defp execute_server_stream(call_opts) do
    %{service: service, method: method, channel: channel, message: message} = call_opts
    
    request_fun = fn ->
      service.server_stream(channel, method, message,
        timeout: call_opts.timeout,
        headers: call_opts.headers
      )
    end
    
    case call_opts.retry do
      [] ->
        request_fun.()
      
      retry_opts when is_list(retry_opts) ->
        FaultTolerance.with_retry(request_fun, retry_opts)
    end
  end

  defp execute_client_stream(call_opts) do
    %{service: service, method: method, channel: channel} = call_opts
    
    request_fun = fn ->
      service.client_stream(channel, method,
        timeout: call_opts.timeout,
        headers: call_opts.headers
      )
    end
    
    case call_opts.retry do
      [] ->
        request_fun.()
      
      retry_opts when is_list(retry_opts) ->
        FaultTolerance.with_retry(request_fun, retry_opts)
    end
  end

  defp execute_bidirectional_stream(call_opts) do
    %{service: service, method: method, channel: channel} = call_opts
    
    request_fun = fn ->
      service.bidirectional_stream(channel, method,
        timeout: call_opts.timeout,
        headers: call_opts.headers
      )
    end
    
    case call_opts.retry do
      [] ->
        request_fun.()
      
      retry_opts when is_list(retry_opts) ->
        FaultTolerance.with_retry(request_fun, retry_opts)
    end
  end

  defp emit_telemetry(operation, result, opts, start_time, end_time, error \\ nil) do
    duration = end_time - start_time
    
    metadata = %{
      adapter: :grpc,
      operation: operation,
      service: Keyword.get(opts, :service),
      method: Keyword.get(opts, :method),
      host: Keyword.get(opts, :host),
      port: Keyword.get(opts, :port),
      result: result
    }
    
    metadata = if error, do: Map.put(metadata, :error, error), else: metadata
    
    :telemetry.execute(
      [:vsm_connections, :adapter, :grpc],
      %{duration: duration},
      metadata
    )
  end
end