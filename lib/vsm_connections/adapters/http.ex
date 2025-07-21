defmodule VsmConnections.Adapters.HTTP do
  @moduledoc """
  HTTP adapter for VSM Connections using Finch.
  
  This adapter provides HTTP/HTTPS connectivity with:
  - Connection pooling via Finch
  - Automatic retries with exponential backoff
  - Request/response telemetry
  - Circuit breaker integration
  - Configurable timeouts and headers
  """

  alias VsmConnections.Config
  alias VsmConnections.FaultTolerance

  @default_timeout 5_000
  @default_headers [{"user-agent", "VSM-Connections/0.1.0"}]

  @doc """
  Makes an HTTP request using the configured connection pool.
  
  ## Options
  
  - `:method` - HTTP method (:get, :post, :put, :delete, etc.)
  - `:url` - Full URL or path if using a pool
  - `:headers` - Additional headers
  - `:body` - Request body
  - `:pool` - Pool name to use
  - `:timeout` - Request timeout in milliseconds
  - `:retry` - Retry configuration
  - `:follow_redirects` - Whether to follow redirects (default: true)
  
  ## Examples
  
      # Simple GET request
      {:ok, response} = VsmConnections.Adapters.HTTP.request(
        method: :get,
        url: "https://api.example.com/users"
      )
      
      # POST with body and custom headers
      {:ok, response} = VsmConnections.Adapters.HTTP.request(
        method: :post,
        url: "https://api.example.com/users",
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{name: "John", email: "john@example.com"}),
        timeout: 10_000
      )
      
      # Using a specific pool
      {:ok, response} = VsmConnections.Adapters.HTTP.request(
        method: :get,
        url: "/health",
        pool: :api_pool
      )
  """
  @spec request(keyword()) :: {:ok, map()} | {:error, term()}
  def request(opts) do
    start_time = System.monotonic_time()
    
    with {:ok, finch_request} <- build_request(opts),
         {:ok, response} <- execute_request(finch_request, opts) do
      
      end_time = System.monotonic_time()
      emit_telemetry(:success, opts, start_time, end_time)
      
      {:ok, format_response(response)}
    else
      {:error, reason} ->
        end_time = System.monotonic_time()
        emit_telemetry(:error, opts, start_time, end_time, reason)
        {:error, reason}
    end
  end

  @doc """
  Makes a GET request.
  
  ## Examples
  
      {:ok, response} = VsmConnections.Adapters.HTTP.get("https://api.example.com/users")
      {:ok, response} = VsmConnections.Adapters.HTTP.get("/health", pool: :api_pool)
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(url, opts \\ []) do
    request([method: :get, url: url] ++ opts)
  end

  @doc """
  Makes a POST request.
  
  ## Examples
  
      {:ok, response} = VsmConnections.Adapters.HTTP.post(
        "https://api.example.com/users",
        %{name: "John"},
        headers: [{"content-type", "application/json"}]
      )
  """
  @spec post(String.t(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(url, body, opts \\ []) do
    request([method: :post, url: url, body: encode_body(body)] ++ opts)
  end

  @doc """
  Makes a PUT request.
  """
  @spec put(String.t(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(url, body, opts \\ []) do
    request([method: :put, url: url, body: encode_body(body)] ++ opts)
  end

  @doc """
  Makes a PATCH request.
  """
  @spec patch(String.t(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def patch(url, body, opts \\ []) do
    request([method: :patch, url: url, body: encode_body(body)] ++ opts)
  end

  @doc """
  Makes a DELETE request.
  """
  @spec delete(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(url, opts \\ []) do
    request([method: :delete, url: url] ++ opts)
  end

  @doc """
  Streams an HTTP request and calls the given function for each chunk.
  
  ## Examples
  
      VsmConnections.Adapters.HTTP.stream(
        method: :get,
        url: "https://api.example.com/large-file",
        fun: fn chunk, acc ->
          IO.write(chunk)
          {:cont, acc}
        end
      )
  """
  @spec stream(keyword()) :: {:ok, term()} | {:error, term()}
  def stream(opts) do
    fun = Keyword.fetch!(opts, :fun)
    acc = Keyword.get(opts, :acc, nil)
    
    with {:ok, finch_request} <- build_request(opts) do
      finch_name = get_finch_name(opts)
      
      Finch.stream(finch_request, finch_name, acc, fun,
        receive_timeout: Keyword.get(opts, :timeout, @default_timeout)
      )
    end
  end

  # Private functions

  defp build_request(opts) do
    method = Keyword.fetch!(opts, :method)
    url = build_url(opts)
    headers = build_headers(opts)
    body = Keyword.get(opts, :body, "")
    
    request = Finch.build(method, url, headers, body)
    {:ok, request}
  rescue
    error -> {:error, {:build_request_failed, error}}
  end

  defp build_url(opts) do
    case {Keyword.get(opts, :url), Keyword.get(opts, :pool)} do
      {url, nil} when is_binary(url) ->
        url
      
      {path, pool_name} when is_binary(path) and is_atom(pool_name) ->
        case get_pool_config(pool_name) do
          %{host: host, port: port, scheme: scheme} ->
            "#{scheme}://#{host}:#{port}#{path}"
          nil ->
            throw({:error, {:unknown_pool, pool_name}})
        end
      
      {nil, _} ->
        throw({:error, :missing_url})
      
      {url, _pool} when is_binary(url) ->
        url
    end
  end

  defp build_headers(opts) do
    custom_headers = Keyword.get(opts, :headers, [])
    
    @default_headers
    |> merge_headers(custom_headers)
    |> add_content_type_if_needed(opts)
  end

  defp merge_headers(default_headers, custom_headers) do
    custom_keys = Enum.map(custom_headers, fn {key, _} -> String.downcase(key) end)
    
    default_headers
    |> Enum.reject(fn {key, _} -> String.downcase(key) in custom_keys end)
    |> Kernel.++(custom_headers)
  end

  defp add_content_type_if_needed(headers, opts) do
    has_content_type? = 
      headers
      |> Enum.any?(fn {key, _} -> String.downcase(key) == "content-type" end)
    
    case {has_content_type?, Keyword.get(opts, :body)} do
      {false, body} when is_binary(body) and body != "" ->
        [{"content-type", "application/octet-stream"} | headers]
      _ ->
        headers
    end
  end

  defp execute_request(finch_request, opts) do
    finch_name = get_finch_name(opts)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    retry_config = Keyword.get(opts, :retry, [])
    
    request_fun = fn ->
      Finch.request(finch_request, finch_name, receive_timeout: timeout)
    end
    
    case retry_config do
      [] ->
        request_fun.()
      
      retry_opts when is_list(retry_opts) ->
        FaultTolerance.with_retry(request_fun, retry_opts)
    end
  end

  defp get_finch_name(opts) do
    case Keyword.get(opts, :pool) do
      nil -> VsmConnections.Finch
      pool_name -> get_pool_finch_name(pool_name)
    end
  end

  defp get_pool_finch_name(pool_name) do
    # This would typically come from the pool manager
    # For now, we'll use the default Finch instance
    VsmConnections.Finch
  end

  defp get_pool_config(pool_name) do
    Config.get([:pools, pool_name])
  end

  defp format_response(%Finch.Response{status: status, headers: headers, body: body}) do
    %{
      status: status,
      headers: headers,
      body: decode_body(body, headers)
    }
  end

  defp decode_body(body, headers) do
    content_type = get_content_type(headers)
    
    case content_type do
      "application/json" ->
        case Jason.decode(body) do
          {:ok, json} -> json
          {:error, _} -> body
        end
      
      "application/x-msgpack" ->
        case :msgpax.unpack(body) do
          {:ok, data} -> data
          {:error, _} -> body
        end
      
      _ ->
        body
    end
  rescue
    _ -> body
  end

  defp get_content_type(headers) do
    headers
    |> Enum.find(fn {key, _} -> String.downcase(key) == "content-type" end)
    |> case do
      {_, value} -> 
        value
        |> String.split(";")
        |> List.first()
        |> String.trim()
        |> String.downcase()
      nil -> 
        ""
    end
  end

  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body) when is_map(body) or is_list(body) do
    Jason.encode!(body)
  end
  defp encode_body(body), do: to_string(body)

  defp emit_telemetry(result, opts, start_time, end_time, error \\ nil) do
    duration = end_time - start_time
    method = Keyword.get(opts, :method, :unknown)
    
    metadata = %{
      adapter: :http,
      method: method,
      url: Keyword.get(opts, :url),
      pool: Keyword.get(opts, :pool)
    }
    
    metadata = if error, do: Map.put(metadata, :error, error), else: metadata
    
    :telemetry.execute(
      [:vsm_connections, :adapter, :request],
      %{duration: duration},
      Map.put(metadata, :result, result)
    )
  end
end