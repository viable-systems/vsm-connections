defmodule VsmConnections.Adapters.HttpAdapter do
  @moduledoc """
  HTTP/HTTPS adapter for VSM connections.
  
  Provides RESTful API integration with the VSM using Finch for high-performance
  HTTP client capabilities.
  """

  @behaviour VsmConnections.Adapters.AdapterBehaviour

  require Logger
  alias VsmConnections.Transformation.Pipeline

  @default_pool_config %{
    size: 10,
    count: 1,
    max_idle_time: 30_000
  }

  @default_timeout 5_000

  # Type definitions
  @type connection :: %{
    pool_name: atom(),
    base_url: String.t(),
    headers: [{String.t(), String.t()}],
    timeout: integer()
  }

  @impl true
  def connect(opts) do
    pool_name = Keyword.get(opts, :pool_name, :default_http_pool)
    base_url = Keyword.fetch!(opts, :base_url)
    
    pool_config = opts
    |> Keyword.get(:pool_config, @default_pool_config)
    |> Map.merge(%{
      conn_opts: [
        transport_opts: [
          timeout: opts[:connect_timeout] || 10_000,
          inet6: opts[:inet6] || false
        ]
      ]
    })
    
    # Configure Finch pool
    case configure_pool(pool_name, base_url, pool_config) do
      :ok ->
        connection = %{
          pool_name: pool_name,
          base_url: base_url,
          headers: build_default_headers(opts),
          timeout: opts[:timeout] || @default_timeout
        }
        
        {:ok, connection}
        
      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  @impl true
  def send(connection, message) do
    with {:ok, request} <- build_request(connection, message),
         {:ok, response} <- execute_request(request, connection) do
      parse_response(response)
    end
  end

  @impl true
  def receive(_connection, _opts) do
    # HTTP is request-response, so receive is not applicable
    {:error, :not_supported}
  end

  @impl true
  def disconnect(connection) do
    # Finch pools are managed globally, so we just log
    Logger.debug("HTTP adapter disconnecting", pool: connection.pool_name)
    :ok
  end

  @impl true
  def transform_inbound(message, metadata) do
    pipeline = Pipeline.build_pipeline([
      {:validate, schema: :http_request},
      {:normalize, rules: [:extract_http_fields]},
      {:enrich, metadata: Map.to_list(metadata)},
      {:map_to_vsm, mapping: :http_request_mapping}
    ])
    
    Pipeline.transform(message, pipeline)
  end

  @impl true
  def transform_outbound(vsm_message, metadata) do
    pipeline = Pipeline.build_pipeline([
      {:validate, schema: :vsm_message},
      {:map_from_vsm, mapping: :vsm_to_http_mapping},
      {:enrich, metadata: Map.to_list(metadata)},
      {:normalize, rules: [:format_http_response]}
    ])
    
    Pipeline.transform(vsm_message, pipeline)
  end

  @impl true
  def health_check(connection) do
    health_endpoint = build_url(connection, "/health")
    
    request = Finch.build(:get, health_endpoint, connection.headers)
    
    case Finch.request(request, connection.pool_name, timeout: 2_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        :healthy
        
      {:ok, %{status: status}} when status in 500..599 ->
        :unhealthy
        
      {:ok, _} ->
        :degraded
        
      {:error, _} ->
        :unhealthy
    end
  end

  @impl true
  def get_metrics() do
    %{
      active_connections: get_pool_metrics(:active),
      idle_connections: get_pool_metrics(:idle),
      total_requests: get_counter(:http_requests_total),
      failed_requests: get_counter(:http_requests_failed),
      average_latency_ms: get_histogram(:http_request_duration_ms)
    }
  end

  @impl true
  def validate_config(config) do
    required_keys = [:base_url]
    
    case Enum.filter(required_keys, &(not Map.has_key?(config, &1))) do
      [] -> :ok
      missing -> {:error, {:missing_config, missing}}
    end
  end

  @impl true
  def capabilities() do
    %{
      streaming: false,
      bidirectional: false,
      ordered_delivery: true,
      reliable_delivery: true,
      max_message_size: 10 * 1024 * 1024  # 10MB default
    }
  end

  @impl true
  def handle_error(error) do
    case error do
      {:error, :timeout} ->
        {:timeout, "Request timed out"}
        
      {:error, :econnrefused} ->
        {:recoverable, "Connection refused"}
        
      {:error, :closed} ->
        {:recoverable, "Connection closed"}
        
      {:error, {:tls_alert, alert}} ->
        {:permanent, "TLS error: #{inspect(alert)}"}
        
      {:error, reason} ->
        {:recoverable, "Unknown error: #{inspect(reason)}"}
    end
  end

  # Private functions

  defp configure_pool(pool_name, base_url, pool_config) do
    uri = URI.parse(base_url)
    
    pool_opts = [
      name: pool_name,
      scheme: String.to_atom(uri.scheme || "http"),
      host: uri.host,
      port: uri.port || default_port(uri.scheme)
    ] ++ pool_config
    
    # In a real implementation, this would configure the Finch pool
    # For now, we'll assume it's configured at application startup
    :ok
  end

  defp default_port("https"), do: 443
  defp default_port(_), do: 80

  defp build_default_headers(opts) do
    base_headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"user-agent", "vsm-connections/1.0"}
    ]
    
    custom_headers = Keyword.get(opts, :headers, [])
    
    # Add authentication headers if provided
    auth_headers = case opts[:auth] do
      {:bearer, token} ->
        [{"authorization", "Bearer #{token}"}]
        
      {:basic, {username, password}} ->
        credentials = Base.encode64("#{username}:#{password}")
        [{"authorization", "Basic #{credentials}"}]
        
      _ ->
        []
    end
    
    base_headers ++ auth_headers ++ custom_headers
  end

  defp build_request(connection, message) do
    method = message[:method] || :post
    path = message[:path] || "/"
    url = build_url(connection, path)
    
    headers = merge_headers(connection.headers, message[:headers] || [])
    
    body = case message[:body] do
      nil -> nil
      body when is_map(body) -> Jason.encode!(body)
      body -> body
    end
    
    request = Finch.build(method, url, headers, body)
    {:ok, request}
  rescue
    exception ->
      {:error, {:request_build_failed, exception}}
  end

  defp build_url(connection, path) do
    base = String.trim_trailing(connection.base_url, "/")
    path = String.trim_leading(path, "/")
    "#{base}/#{path}"
  end

  defp merge_headers(base_headers, additional_headers) do
    # Convert to maps for easier merging
    base_map = Map.new(base_headers)
    additional_map = Map.new(additional_headers)
    
    # Merge with additional headers taking precedence
    Map.merge(base_map, additional_map)
    |> Map.to_list()
  end

  defp execute_request(request, connection) do
    start_time = System.monotonic_time()
    
    result = Finch.request(
      request, 
      connection.pool_name,
      timeout: connection.timeout
    )
    
    duration = System.monotonic_time() - start_time
    record_request_metrics(request, result, duration)
    
    result
  end

  defp parse_response({:ok, %{status: status, headers: headers, body: body}}) do
    parsed_body = parse_body(body, headers)
    
    response = %{
      status: status,
      headers: headers,
      body: parsed_body,
      success?: status in 200..299
    }
    
    {:ok, response}
  end

  defp parse_response({:error, reason}) do
    {:error, reason}
  end

  defp parse_body(body, headers) do
    content_type = get_content_type(headers)
    
    case content_type do
      "application/json" <> _ ->
        case Jason.decode(body) do
          {:ok, parsed} -> parsed
          {:error, _} -> body
        end
        
      _ ->
        body
    end
  end

  defp get_content_type(headers) do
    headers
    |> Enum.find(fn {name, _} -> String.downcase(name) == "content-type" end)
    |> case do
      {_, content_type} -> content_type
      nil -> "text/plain"
    end
  end

  defp record_request_metrics(request, result, duration) do
    labels = %{
      method: request.method,
      status: case result do
        {:ok, %{status: status}} -> status
        {:error, _} -> "error"
      end
    }
    
    :telemetry.execute(
      [:vsm_connections, :http, :request],
      %{duration: duration},
      labels
    )
  end

  defp get_pool_metrics(type) do
    # In a real implementation, this would query Finch pool metrics
    0
  end

  defp get_counter(metric) do
    # In a real implementation, this would query telemetry metrics
    0
  end

  defp get_histogram(metric) do
    # In a real implementation, this would query telemetry metrics
    0.0
  end
end