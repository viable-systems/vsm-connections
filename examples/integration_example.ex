defmodule VsmConnections.Examples.IntegrationExample do
  @moduledoc """
  Comprehensive examples demonstrating VSM integration architecture usage.
  
  Shows how to integrate external systems with the Viable System Model
  using various protocols and patterns.
  """

  alias VsmConnections.Integration.Manager
  alias VsmConnections.Configuration.ConfigManager
  alias VsmConnections.Resilience.CircuitBreakerManager

  # Example 1: Basic HTTP Integration
  def http_integration_example do
    # Configure HTTP adapter
    ConfigManager.update_config(:http_adapter, %{
      base_url: "https://api.example.com",
      timeout: 5_000,
      pool_size: 10,
      auth: {:bearer, "your-api-token"}
    })
    
    # Send a message through HTTP
    message = %{
      protocol: :http,
      method: :post,
      path: "/v1/data",
      body: %{
        metric: "temperature",
        value: 23.5,
        timestamp: DateTime.utc_now()
      }
    }
    
    case Manager.send_message(message) do
      {:ok, response} ->
        IO.puts("HTTP request successful: #{inspect(response)}")
        
      {:error, :circuit_open} ->
        IO.puts("Circuit breaker is open - service unavailable")
        
      {:error, reason} ->
        IO.puts("HTTP request failed: #{inspect(reason)}")
    end
  end

  # Example 2: WebSocket Real-time Integration
  def websocket_integration_example do
    # Establish WebSocket connection
    {:ok, conn_ref} = Manager.connect(:websocket, 
      url: "wss://stream.example.com/socket",
      auth: {:bearer, "your-token"},
      handler: self()
    )
    
    # Subscribe to real-time updates
    subscription_message = %{
      type: "subscribe",
      topics: ["market_data", "system_alerts"],
      connection: conn_ref
    }
    
    Manager.send_message(subscription_message, connection: conn_ref)
    
    # Handle incoming messages
    receive_loop(conn_ref)
  end

  defp receive_loop(conn_ref) do
    receive do
      {:websocket_message, message} ->
        handle_websocket_message(message)
        receive_loop(conn_ref)
        
      {:websocket_disconnected, ^conn_ref, reason} ->
        IO.puts("WebSocket disconnected: #{inspect(reason)}")
        # Optionally reconnect
        
      :stop ->
        Manager.disconnect(conn_ref)
        :ok
    end
  end

  defp handle_websocket_message(message) do
    # Messages are automatically routed to appropriate VSM subsystem
    IO.puts("Received WebSocket message: #{inspect(message)}")
    
    # The message has already been:
    # 1. Transformed to VSM format
    # 2. Routed to appropriate subsystem
    # 3. Processed by VSM core
  end

  # Example 3: gRPC Service Integration
  def grpc_integration_example do
    # Configure gRPC adapter
    ConfigManager.update_config(:grpc_adapter, %{
      host: "grpc.example.com",
      port: 443,
      ssl: true,
      channel_args: %{
        "grpc.keepalive_time_ms" => 10_000
      }
    })
    
    # Make a gRPC call
    grpc_message = %{
      protocol: :grpc,
      service: MyApp.ServiceModule,
      method: :process_data,
      request: %MyApp.ProcessRequest{
        data: "example data",
        options: %{format: :json}
      }
    }
    
    case Manager.send_message(grpc_message) do
      {:ok, %MyApp.ProcessResponse{} = response} ->
        IO.puts("gRPC call successful: #{inspect(response)}")
        
      {:error, reason} ->
        IO.puts("gRPC call failed: #{inspect(reason)}")
    end
  end

  # Example 4: Multi-Protocol Coordination
  def multi_protocol_example do
    # Scenario: Receive data via WebSocket, process it, 
    # and send results via HTTP while monitoring via gRPC
    
    # 1. Setup WebSocket for data ingestion
    {:ok, ws_conn} = Manager.connect(:websocket,
      url: "wss://data.example.com/stream"
    )
    
    # 2. Configure HTTP for result submission
    ConfigManager.update_config(:http_adapter, %{
      base_url: "https://results.example.com"
    })
    
    # 3. Setup gRPC for monitoring
    {:ok, grpc_conn} = Manager.connect(:grpc,
      host: "monitoring.example.com",
      port: 443
    )
    
    # Process incoming data
    Task.start(fn ->
      process_multi_protocol_flow(ws_conn, grpc_conn)
    end)
  end

  defp process_multi_protocol_flow(ws_conn, grpc_conn) do
    receive do
      {:websocket_message, data} ->
        # Data automatically routed to VSM for processing
        
        # VSM processes and generates response
        result = process_through_vsm(data)
        
        # Send result via HTTP
        http_message = %{
          protocol: :http,
          method: :post,
          path: "/results",
          body: result
        }
        
        Manager.send_message(http_message)
        
        # Send monitoring update via gRPC
        monitor_message = %{
          protocol: :grpc,
          connection: grpc_conn,
          service: MonitoringService,
          method: :record_metric,
          request: %MetricRequest{
            name: "data_processed",
            value: 1,
            tags: %{source: "websocket", destination: "http"}
          }
        }
        
        Manager.send_message(monitor_message)
        
        # Continue processing
        process_multi_protocol_flow(ws_conn, grpc_conn)
    end
  end

  # Example 5: Circuit Breaker Patterns
  def circuit_breaker_example do
    # Configure circuit breakers for different services
    CircuitBreakerManager.register(:payment_service, %{
      failure_threshold: 5,
      recovery_timeout: 60_000,
      call_timeout: 3_000
    })
    
    CircuitBreakerManager.register(:inventory_service, %{
      failure_threshold: 3,
      recovery_timeout: 30_000,
      call_timeout: 5_000
    })
    
    # Use circuit breakers
    order = %{
      items: [%{sku: "ABC123", quantity: 2}],
      payment: %{method: :credit_card, amount: 99.99}
    }
    
    process_order_with_circuit_breakers(order)
  end

  defp process_order_with_circuit_breakers(order) do
    # Check inventory with circuit breaker
    inventory_result = CircuitBreakerManager.call(:inventory_service, fn ->
      check_inventory(order.items)
    end)
    
    case inventory_result do
      {:ok, :available} ->
        # Process payment with circuit breaker
        payment_result = CircuitBreakerManager.call(:payment_service, fn ->
          process_payment(order.payment)
        end)
        
        case payment_result do
          {:ok, transaction_id} ->
            IO.puts("Order processed successfully: #{transaction_id}")
            
          {:error, :circuit_open} ->
            IO.puts("Payment service unavailable - circuit open")
            # Could implement fallback to queue for later processing
            
          {:error, reason} ->
            IO.puts("Payment failed: #{inspect(reason)}")
        end
        
      {:error, :circuit_open} ->
        IO.puts("Inventory service unavailable - circuit open")
        
      {:error, _reason} ->
        IO.puts("Inventory check failed")
    end
  end

  # Example 6: Custom Adapter Integration
  def custom_adapter_example do
    # Register a custom adapter for a proprietary protocol
    defmodule CustomAdapter do
      @behaviour VsmConnections.Adapters.AdapterBehaviour
      
      # Implement all required callbacks
      def connect(opts) do
        # Custom connection logic
        {:ok, %{connected: true, opts: opts}}
      end
      
      def send(connection, message) do
        # Custom send logic
        IO.puts("Sending via custom adapter: #{inspect(message)}")
        {:ok, %{status: :sent}}
      end
      
      # ... implement other required callbacks
    end
    
    # Use the custom adapter
    message = %{
      protocol: :custom,
      adapter: CustomAdapter,
      data: "proprietary data format"
    }
    
    Manager.send_message(message)
  end

  # Example 7: VSM Subsystem Integration
  def vsm_subsystem_integration_example do
    # Example showing how external messages are routed to VSM subsystems
    
    # Operational message -> System 1
    operational_message = %{
      type: "transaction",
      operation_id: "OP-12345",
      action: :process_order,
      data: %{order_id: "ORD-789"}
    }
    
    # Coordination message -> System 2
    coordination_message = %{
      type: "coordination",
      coordination_token: "COORD-456",
      units: [:unit_a, :unit_b],
      action: :synchronize
    }
    
    # Control message -> System 3
    control_message = %{
      type: "control",
      control_directive: :allocate_resources,
      resources: %{cpu: 0.5, memory: 0.7}
    }
    
    # Intelligence message -> System 4
    intelligence_message = %{
      type: "forecast",
      intelligence_data: %{
        metric: "demand",
        horizon: :days_7,
        confidence: 0.85
      }
    }
    
    # Policy message -> System 5
    policy_message = %{
      type: "policy",
      policy_update: %{
        domain: :security,
        rules: ["enforce_2fa", "audit_all_access"]
      }
    }
    
    # Algedonic signal (emergency)
    algedonic_message = %{
      emergency: true,
      severity: :critical,
      source: :security_system,
      message: "Intrusion detected"
    }
    
    # Send all messages - they'll be automatically routed
    messages = [
      operational_message,
      coordination_message,
      control_message,
      intelligence_message,
      policy_message,
      algedonic_message
    ]
    
    Enum.each(messages, fn message ->
      result = Manager.send_message(message)
      IO.puts("Message routed: #{message.type} -> #{inspect(result)}")
    end)
  end

  # Example 8: Transformation Pipeline Customization
  def custom_transformation_example do
    # Define custom transformation pipeline
    alias VsmConnections.Transformation.Pipeline
    
    # Create a custom transformer
    custom_transformer = fn message ->
      # Add custom processing
      enhanced = Map.put(message, :processed_at, DateTime.utc_now())
      {:ok, enhanced}
    end
    
    # Build pipeline with custom stages
    pipeline = Pipeline.build_pipeline([
      {:validate, schema: :custom_schema},
      {:custom, custom_transformer},
      {:transform_field, field: :amount, with: &convert_currency/1},
      {:enrich, metadata: [:source_ip, :user_agent]},
      {:map_to_vsm, mapping: :financial_transaction}
    ])
    
    # Use the custom pipeline
    message = %{
      amount: %{value: 100, currency: "USD"},
      account: "ACC-123",
      type: :deposit
    }
    
    case Pipeline.transform(message, pipeline) do
      {:ok, transformed} ->
        IO.puts("Transformation successful: #{inspect(transformed)}")
        
      {:error, stage, reason} ->
        IO.puts("Transformation failed at #{stage}: #{inspect(reason)}")
    end
  end

  defp convert_currency(%{value: value, currency: "USD"}) do
    # Convert to base currency (e.g., EUR)
    {:ok, %{value: value * 0.85, currency: "EUR"}}
  end

  # Helper functions for examples
  defp process_through_vsm(data) do
    # Simulate VSM processing
    %{
      processed: true,
      data: data,
      timestamp: DateTime.utc_now()
    }
  end

  defp check_inventory(items) do
    # Simulate inventory check
    Process.sleep(100)
    {:ok, :available}
  end

  defp process_payment(payment) do
    # Simulate payment processing
    Process.sleep(200)
    {:ok, "TXN-#{:rand.uniform(10000)}"}
  end
end