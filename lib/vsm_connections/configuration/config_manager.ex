defmodule VsmConnections.Configuration.ConfigManager do
  @moduledoc """
  Dynamic configuration management for VSM integration adapters.
  
  Provides runtime configuration updates, validation, and hot-reloading
  capabilities for all integration components.
  """

  use GenServer
  require Logger

  @config_path "config/vsm_connections"
  @validation_timeout 5_000

  defmodule State do
    defstruct [
      :configs,
      :validators,
      :change_listeners,
      :config_sources,
      :last_reload
    ]
  end

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets configuration for a specific component.
  """
  @spec get_config(component :: atom()) :: {:ok, map()} | {:error, :not_found}
  def get_config(component) do
    GenServer.call(__MODULE__, {:get_config, component})
  end

  @doc """
  Updates configuration for a component at runtime.
  
  The configuration is validated before being applied.
  """
  @spec update_config(component :: atom(), config :: map()) :: :ok | {:error, term()}
  def update_config(component, config) do
    GenServer.call(__MODULE__, {:update_config, component, config}, @validation_timeout)
  end

  @doc """
  Registers a configuration validator for a component.
  
  The validator function should return :ok or {:error, reason}.
  """
  @spec register_validator(component :: atom(), validator :: function()) :: :ok
  def register_validator(component, validator) when is_function(validator, 1) do
    GenServer.call(__MODULE__, {:register_validator, component, validator})
  end

  @doc """
  Registers a change listener for configuration updates.
  
  The listener will be called with (component, old_config, new_config).
  """
  @spec register_change_listener(listener :: function()) :: {:ok, reference()}
  def register_change_listener(listener) when is_function(listener, 3) do
    GenServer.call(__MODULE__, {:register_listener, listener})
  end

  @doc """
  Unregisters a change listener.
  """
  @spec unregister_change_listener(ref :: reference()) :: :ok
  def unregister_change_listener(ref) do
    GenServer.call(__MODULE__, {:unregister_listener, ref})
  end

  @doc """
  Reloads configuration from all sources.
  """
  @spec reload_config() :: :ok | {:error, term()}
  def reload_config() do
    GenServer.call(__MODULE__, :reload_config, @validation_timeout * 2)
  end

  @doc """
  Exports current configuration to a file.
  """
  @spec export_config(path :: String.t()) :: :ok | {:error, term()}
  def export_config(path) do
    GenServer.call(__MODULE__, {:export_config, path})
  end

  @doc """
  Validates a configuration without applying it.
  """
  @spec validate_config(component :: atom(), config :: map()) :: :ok | {:error, term()}
  def validate_config(component, config) do
    GenServer.call(__MODULE__, {:validate_config, component, config})
  end

  # Server Implementation

  @impl true
  def init(opts) do
    # Load initial configuration
    configs = load_initial_configs(opts)
    
    # Setup config sources
    config_sources = setup_config_sources(opts)
    
    # Schedule periodic config reload if enabled
    if opts[:auto_reload] do
      schedule_reload(opts[:reload_interval] || 60_000)
    end
    
    state = %State{
      configs: configs,
      validators: %{},
      change_listeners: %{},
      config_sources: config_sources,
      last_reload: DateTime.utc_now()
    }
    
    {:ok, state}
  end

  @impl true
  def handle_call({:get_config, component}, _from, state) do
    result = case Map.fetch(state.configs, component) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, :not_found}
    end
    
    {:reply, result, state}
  end

  @impl true
  def handle_call({:update_config, component, config}, _from, state) do
    with :ok <- validate_configuration(component, config, state),
         {:ok, merged_config} <- merge_with_existing(component, config, state),
         :ok <- apply_configuration(component, merged_config, state) do
      
      # Update state
      old_config = Map.get(state.configs, component)
      new_configs = Map.put(state.configs, component, merged_config)
      new_state = %{state | configs: new_configs}
      
      # Notify listeners
      notify_listeners(component, old_config, merged_config, state)
      
      {:reply, :ok, new_state}
    else
      {:error, reason} = error ->
        Logger.error("Configuration update failed", 
          component: component,
          reason: reason
        )
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:register_validator, component, validator}, _from, state) do
    validators = Map.put(state.validators, component, validator)
    {:reply, :ok, %{state | validators: validators}}
  end

  @impl true
  def handle_call({:register_listener, listener}, _from, state) do
    ref = make_ref()
    listeners = Map.put(state.change_listeners, ref, listener)
    {:reply, {:ok, ref}, %{state | change_listeners: listeners}}
  end

  @impl true
  def handle_call({:unregister_listener, ref}, _from, state) do
    listeners = Map.delete(state.change_listeners, ref)
    {:reply, :ok, %{state | change_listeners: listeners}}
  end

  @impl true
  def handle_call(:reload_config, _from, state) do
    case reload_all_configs(state) do
      {:ok, new_configs} ->
        # Validate all new configs
        case validate_all_configs(new_configs, state) do
          :ok ->
            # Apply changes
            apply_config_changes(state.configs, new_configs, state)
            
            new_state = %{state | 
              configs: new_configs,
              last_reload: DateTime.utc_now()
            }
            
            {:reply, :ok, new_state}
            
          {:error, reason} ->
            {:reply, {:error, {:validation_failed, reason}}, state}
        end
        
      {:error, reason} ->
        {:reply, {:error, {:reload_failed, reason}}, state}
    end
  end

  @impl true
  def handle_call({:export_config, path}, _from, state) do
    result = export_configs(state.configs, path)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:validate_config, component, config}, _from, state) do
    result = validate_configuration(component, config, state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:reload_config, state) do
    # Async reload
    Task.start(fn ->
      reload_config()
    end)
    
    # Schedule next reload
    schedule_reload(state.config_sources[:reload_interval] || 60_000)
    
    {:noreply, state}
  end

  # Private Functions

  defp load_initial_configs(opts) do
    sources = [
      {:file, Keyword.get(opts, :config_file, "#{@config_path}/default.exs")},
      {:env, Keyword.get(opts, :env_prefix, "VSM_CONNECTIONS_")},
      {:application, :vsm_connections}
    ]
    
    Enum.reduce(sources, %{}, fn source, acc ->
      case load_from_source(source) do
        {:ok, configs} -> Map.merge(acc, configs)
        {:error, _} -> acc
      end
    end)
  end

  defp load_from_source({:file, path}) do
    case File.exists?(path) do
      true ->
        {configs, _} = Code.eval_file(path)
        {:ok, configs}
        
      false ->
        {:error, :not_found}
    end
  rescue
    exception ->
      Logger.error("Failed to load config file", 
        path: path,
        error: exception
      )
      {:error, exception}
  end

  defp load_from_source({:env, prefix}) do
    configs = System.get_env()
    |> Enum.filter(fn {key, _} -> String.starts_with?(key, prefix) end)
    |> Enum.map(fn {key, value} ->
      component = key
      |> String.replace_prefix(prefix, "")
      |> String.downcase()
      |> String.to_atom()
      
      {component, parse_env_value(value)}
    end)
    |> Map.new()
    
    {:ok, configs}
  end

  defp load_from_source({:application, app}) do
    case Application.get_all_env(app) do
      [] -> {:error, :no_config}
      env -> {:ok, Map.new(env)}
    end
  end

  defp parse_env_value(value) do
    cond do
      value =~ ~r/^\d+$/ -> String.to_integer(value)
      value =~ ~r/^\d+\.\d+$/ -> String.to_float(value)
      value in ["true", "false"] -> String.to_existing_atom(value)
      String.starts_with?(value, "{") -> parse_json_value(value)
      true -> value
    end
  end

  defp parse_json_value(value) do
    case Jason.decode(value) do
      {:ok, parsed} -> parsed
      {:error, _} -> value
    end
  end

  defp validate_configuration(component, config, state) do
    # Check if validator exists
    case Map.fetch(state.validators, component) do
      {:ok, validator} ->
        validator.(config)
        
      :error ->
        # Default validation
        validate_default(component, config)
    end
  end

  defp validate_default(component, config) do
    # Basic validation rules
    cond do
      not is_map(config) ->
        {:error, :invalid_format}
        
      component in [:http_adapter, :websocket_adapter, :grpc_adapter] ->
        validate_adapter_config(config)
        
      component == :circuit_breakers ->
        validate_circuit_breaker_config(config)
        
      component == :routing ->
        validate_routing_config(config)
        
      true ->
        :ok
    end
  end

  defp validate_adapter_config(config) do
    required_keys = case config[:protocol] do
      :http -> [:base_url]
      :websocket -> [:url]
      :grpc -> [:host, :port]
      _ -> []
    end
    
    missing = Enum.filter(required_keys, &(not Map.has_key?(config, &1)))
    
    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_required_keys, missing}}
    end
  end

  defp validate_circuit_breaker_config(config) do
    if Map.has_key?(config, :failure_threshold) and 
       Map.has_key?(config, :recovery_timeout) do
      :ok
    else
      {:error, :incomplete_circuit_breaker_config}
    end
  end

  defp validate_routing_config(config) do
    if Map.has_key?(config, :rules) and is_list(config.rules) do
      :ok
    else
      {:error, :invalid_routing_config}
    end
  end

  defp merge_with_existing(component, new_config, state) do
    case Map.fetch(state.configs, component) do
      {:ok, existing} ->
        {:ok, deep_merge(existing, new_config)}
        
      :error ->
        {:ok, new_config}
    end
  end

  defp deep_merge(map1, map2) do
    Map.merge(map1, map2, fn
      _k, v1, v2 when is_map(v1) and is_map(v2) ->
        deep_merge(v1, v2)
        
      _k, _v1, v2 ->
        v2
    end)
  end

  defp apply_configuration(component, config, _state) do
    # Apply configuration to specific components
    case component do
      :http_adapter ->
        VsmConnections.Adapters.HttpAdapter.update_config(config)
        
      :websocket_adapter ->
        VsmConnections.Adapters.WebSocketAdapter.update_config(config)
        
      :circuit_breakers ->
        update_circuit_breakers(config)
        
      :routing ->
        VsmConnections.Routing.MessageRouter.update_config(config)
        
      _ ->
        # Generic update
        :ok
    end
  rescue
    exception ->
      {:error, {:apply_failed, exception}}
  end

  defp update_circuit_breakers(config) do
    Enum.each(config, fn {breaker_name, breaker_config} ->
      VsmConnections.Resilience.CircuitBreakerManager.register(
        breaker_name,
        breaker_config
      )
    end)
  end

  defp notify_listeners(component, old_config, new_config, state) do
    Enum.each(state.change_listeners, fn {_ref, listener} ->
      Task.start(fn ->
        listener.(component, old_config, new_config)
      end)
    end)
  end

  defp reload_all_configs(state) do
    try do
      configs = Enum.reduce(state.config_sources, %{}, fn source, acc ->
        case load_from_source(source) do
          {:ok, source_configs} -> Map.merge(acc, source_configs)
          {:error, _} -> acc
        end
      end)
      
      {:ok, configs}
    rescue
      exception ->
        {:error, exception}
    end
  end

  defp validate_all_configs(configs, state) do
    errors = Enum.reduce(configs, [], fn {component, config}, acc ->
      case validate_configuration(component, config, state) do
        :ok -> acc
        {:error, reason} -> [{component, reason} | acc]
      end
    end)
    
    if Enum.empty?(errors) do
      :ok
    else
      {:error, errors}
    end
  end

  defp apply_config_changes(old_configs, new_configs, state) do
    # Find changed configs
    changes = Enum.filter(new_configs, fn {component, config} ->
      Map.get(old_configs, component) != config
    end)
    
    # Apply each change
    Enum.each(changes, fn {component, config} ->
      old_config = Map.get(old_configs, component)
      
      case apply_configuration(component, config, state) do
        :ok ->
          notify_listeners(component, old_config, config, state)
          Logger.info("Configuration updated", component: component)
          
        {:error, reason} ->
          Logger.error("Failed to apply configuration", 
            component: component,
            reason: reason
          )
      end
    end)
  end

  defp export_configs(configs, path) do
    content = configs
    |> Enum.map(fn {component, config} ->
      ~s(config :vsm_connections, #{inspect(component)}, #{inspect(config, pretty: true)})
    end)
    |> Enum.join("\n\n")
    
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, {:export_failed, reason}}
    end
  end

  defp setup_config_sources(opts) do
    %{
      file_sources: Keyword.get(opts, :config_files, []),
      env_prefix: Keyword.get(opts, :env_prefix, "VSM_CONNECTIONS_"),
      reload_interval: Keyword.get(opts, :reload_interval, 60_000),
      auto_reload: Keyword.get(opts, :auto_reload, false)
    }
  end

  defp schedule_reload(interval) do
    Process.send_after(self(), :reload_config, interval)
  end
end