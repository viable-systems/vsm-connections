defmodule VsmConnections.Transformation.Pipeline do
  @moduledoc """
  Message transformation pipeline for converting between external formats and VSM internal format.
  
  Provides a composable pipeline of transformation steps with error handling,
  validation, and metadata enrichment.
  """

  require Logger
  
  alias VsmConnections.Transformation.{
    SchemaValidator,
    DataNormalizer,
    MetadataEnricher,
    BusinessRules,
    VsmMapper
  }

  @type transformer :: (map() -> {:ok, map()} | {:error, term()})
  @type pipeline :: [transformer()]
  @type transform_result :: {:ok, map()} | {:error, stage :: atom(), reason :: term()}

  @doc """
  Builds a transformation pipeline from a specification.
  
  ## Pipeline Specification
  
  ```elixir
  [
    {:validate, schema: :user_schema},
    {:normalize, rules: [:trim_strings, :lowercase_emails]},
    {:enrich, metadata: [:timestamp, :source_system]},
    {:apply_rules, rules: [:validate_age, :check_permissions]},
    {:map_to_vsm, mapping: :user_mapping}
  ]
  ```
  """
  @spec build_pipeline(pipeline_spec :: list()) :: pipeline()
  def build_pipeline(pipeline_spec) do
    Enum.map(pipeline_spec, &build_transformer/1)
  end

  @doc """
  Executes a transformation pipeline on a message.
  
  Returns the transformed message or an error indicating which stage failed.
  """
  @spec transform(message :: map(), pipeline :: pipeline()) :: transform_result()
  def transform(message, pipeline) do
    Logger.debug("Starting transformation pipeline", message_id: message[:id])
    
    pipeline
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, message}, fn {transformer, index}, {:ok, current_message} ->
      case apply_transformer(transformer, current_message, index) do
        {:ok, transformed} ->
          {:cont, {:ok, transformed}}
          
        {:error, reason} ->
          stage = get_stage_name(transformer)
          Logger.error("Transformation failed at stage #{stage}", 
            reason: reason, 
            stage_index: index
          )
          {:halt, {:error, stage, reason}}
      end
    end)
  end

  @doc """
  Executes a transformation pipeline asynchronously.
  
  Useful for non-blocking transformations in high-throughput scenarios.
  """
  @spec transform_async(message :: map(), pipeline :: pipeline(), callback :: function()) :: :ok
  def transform_async(message, pipeline, callback) do
    Task.start(fn ->
      result = transform(message, pipeline)
      callback.(result)
    end)
    :ok
  end

  @doc """
  Creates a reversible transformation pipeline.
  
  Allows transformations to be undone, useful for bidirectional message conversion.
  """
  @spec build_reversible_pipeline(forward_spec :: list(), reverse_spec :: list()) :: 
    {forward :: pipeline(), reverse :: pipeline()}
  def build_reversible_pipeline(forward_spec, reverse_spec) do
    {build_pipeline(forward_spec), build_pipeline(reverse_spec)}
  end

  # Transformer Builders

  defp build_transformer({:validate, opts}) do
    schema = Keyword.fetch!(opts, :schema)
    fn message ->
      SchemaValidator.validate(message, schema)
    end
  end

  defp build_transformer({:normalize, opts}) do
    rules = Keyword.get(opts, :rules, [])
    fn message ->
      DataNormalizer.normalize(message, rules)
    end
  end

  defp build_transformer({:enrich, opts}) do
    metadata_types = Keyword.get(opts, :metadata, [])
    fn message ->
      MetadataEnricher.enrich(message, metadata_types)
    end
  end

  defp build_transformer({:apply_rules, opts}) do
    rules = Keyword.get(opts, :rules, [])
    fn message ->
      BusinessRules.apply(message, rules)
    end
  end

  defp build_transformer({:map_to_vsm, opts}) do
    mapping = Keyword.fetch!(opts, :mapping)
    fn message ->
      VsmMapper.map_to_vsm(message, mapping)
    end
  end

  defp build_transformer({:map_from_vsm, opts}) do
    mapping = Keyword.fetch!(opts, :mapping)
    fn message ->
      VsmMapper.map_from_vsm(message, mapping)
    end
  end

  defp build_transformer({:custom, transformer}) when is_function(transformer, 1) do
    transformer
  end

  defp build_transformer({:filter, opts}) do
    predicate = Keyword.fetch!(opts, :predicate)
    fn message ->
      if predicate.(message) do
        {:ok, message}
      else
        {:error, :filtered_out}
      end
    end
  end

  defp build_transformer({:transform_field, opts}) do
    field = Keyword.fetch!(opts, :field)
    transformation = Keyword.fetch!(opts, :with)
    
    fn message ->
      case Map.fetch(message, field) do
        {:ok, value} ->
          case transformation.(value) do
            {:ok, transformed_value} ->
              {:ok, Map.put(message, field, transformed_value)}
            error ->
              error
          end
        :error ->
          {:error, {:missing_field, field}}
      end
    end
  end

  defp build_transformer({:merge, opts}) do
    additional_data = Keyword.fetch!(opts, :with)
    
    fn message ->
      {:ok, Map.merge(message, additional_data)}
    end
  end

  defp build_transformer({:split, opts}) do
    splitter = Keyword.fetch!(opts, :by)
    
    fn message ->
      case splitter.(message) do
        messages when is_list(messages) ->
          {:ok, %{split_messages: messages, original: message}}
        error ->
          {:error, {:split_failed, error}}
      end
    end
  end

  # Helper Functions

  defp apply_transformer(transformer, message, index) do
    start_time = System.monotonic_time()
    
    result = transformer.(message)
    
    duration = System.monotonic_time() - start_time
    record_transformer_metrics(index, duration, result)
    
    result
  rescue
    exception ->
      Logger.error("Transformer crashed", 
        exception: exception,
        message: Exception.message(exception),
        stage_index: index
      )
      {:error, {:transformer_crash, exception}}
  end

  defp get_stage_name(transformer) do
    # Extract stage name from transformer function
    case Function.info(transformer)[:module] do
      SchemaValidator -> :validation
      DataNormalizer -> :normalization
      MetadataEnricher -> :enrichment
      BusinessRules -> :business_rules
      VsmMapper -> :vsm_mapping
      _ -> :custom
    end
  end

  defp record_transformer_metrics(index, duration, result) do
    :telemetry.execute(
      [:vsm_connections, :transformation, :stage],
      %{duration: duration},
      %{
        stage_index: index,
        success: match?({:ok, _}, result)
      }
    )
  end

  @doc """
  Pre-built pipeline for common HTTP to VSM transformations.
  """
  def http_to_vsm_pipeline do
    build_pipeline([
      {:validate, schema: :http_request},
      {:normalize, rules: [:extract_headers, :parse_json_body]},
      {:enrich, metadata: [:timestamp, :http_metadata]},
      {:apply_rules, rules: [:check_auth, :validate_permissions]},
      {:map_to_vsm, mapping: :http_to_vsm}
    ])
  end

  @doc """
  Pre-built pipeline for VSM to HTTP response transformations.
  """
  def vsm_to_http_pipeline do
    build_pipeline([
      {:validate, schema: :vsm_response},
      {:map_from_vsm, mapping: :vsm_to_http},
      {:enrich, metadata: [:response_headers]},
      {:normalize, rules: [:format_json_response]}
    ])
  end

  @doc """
  Pre-built pipeline for WebSocket message transformations.
  """
  def websocket_pipeline do
    build_pipeline([
      {:validate, schema: :websocket_message},
      {:normalize, rules: [:parse_ws_frame]},
      {:enrich, metadata: [:connection_id, :timestamp]},
      {:map_to_vsm, mapping: :websocket_to_vsm}
    ])
  end

  @doc """
  Pre-built pipeline for gRPC transformations.
  """
  def grpc_pipeline do
    build_pipeline([
      {:validate, schema: :grpc_message},
      {:normalize, rules: [:decode_protobuf]},
      {:enrich, metadata: [:grpc_metadata, :deadline]},
      {:map_to_vsm, mapping: :grpc_to_vsm}
    ])
  end

  @doc """
  Composes multiple pipelines into a single pipeline.
  """
  @spec compose(pipelines :: [pipeline()]) :: pipeline()
  def compose(pipelines) do
    List.flatten(pipelines)
  end

  @doc """
  Creates a conditional pipeline that chooses transformers based on message content.
  """
  @spec conditional(condition :: function(), true_pipeline :: pipeline(), false_pipeline :: pipeline()) :: pipeline()
  def conditional(condition, true_pipeline, false_pipeline) do
    [fn message ->
      pipeline = if condition.(message), do: true_pipeline, else: false_pipeline
      transform(message, pipeline)
    end]
  end

  @doc """
  Creates a pipeline that catches and handles errors.
  """
  @spec with_error_handler(pipeline :: pipeline(), error_handler :: function()) :: pipeline()
  def with_error_handler(pipeline, error_handler) do
    [fn message ->
      case transform(message, pipeline) do
        {:ok, _} = success -> success
        {:error, stage, reason} = error ->
          case error_handler.(message, stage, reason) do
            {:recover, recovered_message} -> {:ok, recovered_message}
            :skip -> {:ok, message}
            _ -> error
          end
      end
    end]
  end
end