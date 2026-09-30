# RubyLLM Tools - MCP (Model Context Protocol) Support

## Overview

Model Context Protocol (MCP) is an open standard for connecting AI applications with data sources and tools. RubyLLM provides MCP support through the `ruby_llm-mcp` gem, enabling integration with MCP servers and expanding your tool capabilities.

## What is MCP?

MCP (Model Context Protocol) provides:

- **Standardized tool integration** - Connect to any MCP-compatible server
- **Resource management** - Access files, databases, and APIs through a unified interface
- **Dynamic capabilities** - Discover available tools and resources at runtime
- **Multi-transport support** - HTTP, STDIO, and Server-Sent Events (SSE)

## Installation and Setup

Add the MCP gem to your Rails application:

```ruby
# Gemfile
gem 'ruby_llm'
gem 'ruby_llm-mcp'

# Bundle install
bundle install
```

### Basic Configuration

```ruby
# config/initializers/ruby_llm_mcp.rb
require 'ruby_llm/mcp'

RubyLLM.configure do |config|
  config.openai_api_key = Rails.application.credentials.openai_api_key
end

# Configure MCP clients
MCP_CLIENTS = {
  filesystem: RubyLLM::MCP.client(
    name: "filesystem-server",
    transport_type: :stdio,
    config: {
      command: "mcp-server-filesystem",
      args: [Rails.root.to_s]
    }
  ),

  database: RubyLLM::MCP.client(
    name: "database-server",
    transport_type: :http,
    config: {
      url: "http://localhost:8080/mcp"
    }
  ),

  api_gateway: RubyLLM::MCP.client(
    name: "api-gateway",
    transport_type: :sse,
    config: {
      url: "http://localhost:9292/mcp/sse"
    }
  )
}
```

## MCP Client Types

### STDIO Transport

For local MCP servers that communicate via stdin/stdout:

```ruby
class LocalMCPService
  def initialize
    @filesystem_client = RubyLLM::MCP.client(
      name: "local-filesystem",
      transport_type: :stdio,
      config: {
        command: "bunx",
        args: ["@modelcontextprotocol/server-filesystem", Rails.root.to_s],
        env: { "NODE_ENV" => "production" }
      }
    )
  end

  def available_tools
    @filesystem_client.list_tools
  end

  def call_tool(name, arguments)
    @filesystem_client.call_tool(name, arguments)
  end

  def list_resources
    @filesystem_client.list_resources
  end
end
```

### HTTP Transport

For MCP servers accessible via HTTP:

```ruby
class HTTPMCPService
  def initialize
    @api_client = RubyLLM::MCP.client(
      name: "api-server",
      transport_type: :http,
      config: {
        url: "https://mcp-server.example.com/api",
        headers: {
          "Authorization" => "Bearer #{Rails.application.credentials.mcp_token}",
          "X-App-ID" => Rails.application.name
        },
        timeout: 30
      }
    )
  end

  def weather_tools
    # Get weather-related tools from MCP server
    all_tools = @api_client.list_tools
    all_tools.select { |tool| tool.name.include?("weather") }
  end

  def call_weather_api(location)
    @api_client.call_tool("get_weather", { location: location })
  end
end
```

### Server-Sent Events (SSE) Transport

For real-time MCP communication:

```ruby
class StreamingMCPService
  def initialize
    @streaming_client = RubyLLM::MCP.client(
      name: "streaming-server",
      transport_type: :sse,
      config: {
        url: "http://localhost:9292/mcp/sse",
        headers: {
          "Accept" => "text/event-stream",
          "Cache-Control" => "no-cache"
        }
      }
    )
  end

  def subscribe_to_updates
    @streaming_client.on_resource_update do |resource|
      Rails.logger.info("Resource updated: #{resource.uri}")
      handle_resource_update(resource)
    end
  end

  private

  def handle_resource_update(resource)
    # Process resource updates from MCP server
    case resource.mime_type
    when "application/json"
      process_json_update(resource)
    when "text/plain"
      process_text_update(resource)
    end
  end
end
```

## Integrating MCP Tools with RubyLLM

### Converting MCP Tools to RubyLLM Tools

```ruby
class MCPToolAdapter < RubyLLM::Tool
  def self.from_mcp_client(client, tool_name)
    mcp_tool = client.get_tool(tool_name)

    # Dynamically create RubyLLM tool from MCP tool definition
    Class.new(self) do
      description mcp_tool.description

      # Convert MCP parameters to RubyLLM parameters
      mcp_tool.input_schema&.dig("properties")&.each do |param_name, param_def|
        param param_name.to_sym,
              desc: param_def["description"],
              type: convert_json_type(param_def["type"]),
              required: mcp_tool.input_schema.dig("required")&.include?(param_name)
      end

      define_method :execute do |**kwargs|
        # Call the MCP tool
        result = client.call_tool(tool_name, kwargs)

        # Handle MCP response
        if result.is_error
          { error: result.error_message }
        else
          parse_mcp_result(result)
        end
      end

      private

      define_method :parse_mcp_result do |result|
        case result.content_type
        when "application/json"
          JSON.parse(result.content)
        when "text/plain"
          result.content
        else
          {
            content: result.content,
            content_type: result.content_type
          }
        end
      end
    end
  end

  private

  def self.convert_json_type(json_type)
    case json_type
    when "string" then :string
    when "number" then :number
    when "integer" then :integer
    when "boolean" then :boolean
    when "array" then :array
    when "object" then :object
    else :string
    end
  end
end
```

### Dynamic Tool Registration

```ruby
class DynamicMCPChat
  def initialize(user)
    @user = user
    @mcp_clients = load_user_mcp_clients(user)
  end

  def create_chat
    chat = RubyLLM.chat(model: 'gpt-4')

    # Register tools from all MCP clients
    @mcp_clients.each do |client_name, client|
      register_mcp_tools(chat, client, client_name)
    end

    chat
  end

  private

  def load_user_mcp_clients(user)
    clients = {}

    # Load filesystem access if user has permission
    if user.can_access_files?
      clients[:filesystem] = create_filesystem_client(user)
    end

    # Load database access based on user role
    if user.admin? || user.analyst?
      clients[:database] = create_database_client(user)
    end

    # Load external API access based on subscription
    if user.premium?
      clients[:external_apis] = create_api_client(user)
    end

    clients
  end

  def register_mcp_tools(chat, client, client_name)
    available_tools = client.list_tools

    available_tools.each do |mcp_tool|
      # Convert MCP tool to RubyLLM tool
      ruby_tool = MCPToolAdapter.from_mcp_client(client, mcp_tool.name)

      # Add client context for debugging
      ruby_tool.define_singleton_method :mcp_client_name do
        client_name
      end

      chat.with_tool(ruby_tool)
    end
  rescue => e
    Rails.logger.error("Failed to register MCP tools from #{client_name}: #{e.message}")
  end

  def create_filesystem_client(user)
    # Create user-specific filesystem client with restricted access
    allowed_directories = user.allowed_directories

    RubyLLM::MCP.client(
      name: "user-filesystem-#{user.id}",
      transport_type: :stdio,
      config: {
        command: "mcp-server-filesystem",
        args: allowed_directories,
        env: {
          "USER_ID" => user.id.to_s,
          "ACCESS_LEVEL" => user.access_level
        }
      }
    )
  end
end
```

## Resource Management

MCP provides resource management capabilities beyond just tools:

### Accessing MCP Resources

```ruby
class MCPResourceManager
  def initialize
    @clients = MCP_CLIENTS
  end

  def list_all_resources
    resources = {}

    @clients.each do |name, client|
      begin
        resources[name] = client.list_resources
      rescue => e
        Rails.logger.error("Failed to list resources from #{name}: #{e.message}")
        resources[name] = []
      end
    end

    resources
  end

  def get_resource(client_name, resource_uri)
    client = @clients[client_name]
    return nil unless client

    client.read_resource(resource_uri)
  end

  def search_resources(query)
    results = []

    @clients.each do |name, client|
      begin
        client_resources = client.list_resources
        matching = client_resources.select do |resource|
          resource.name.downcase.include?(query.downcase) ||
          resource.description&.downcase&.include?(query.downcase)
        end

        results.concat(matching.map { |r| { client: name, resource: r } })
      rescue => e
        Rails.logger.error("Search failed for client #{name}: #{e.message}")
      end
    end

    results
  end
end
```

### Using Resources in Tools

```ruby
class MCPResourceTool < RubyLLM::Tool
  description "Access and process resources via MCP"

  param :client_name, desc: "MCP client to use"
  param :resource_uri, desc: "URI of resource to access"
  param :operation, desc: "Operation: read, list, search"

  def execute(client_name:, resource_uri: nil, operation: "read")
    manager = MCPResourceManager.new

    case operation
    when "read"
      return { error: "resource_uri required for read operation" } unless resource_uri

      resource = manager.get_resource(client_name.to_sym, resource_uri)
      if resource
        {
          uri: resource_uri,
          content: resource.content,
          content_type: resource.content_type,
          size: resource.content.bytesize
        }
      else
        { error: "Resource not found: #{resource_uri}" }
      end

    when "list"
      resources = manager.list_all_resources
      {
        clients: resources.keys,
        total_resources: resources.values.map(&:length).sum,
        resources: resources
      }

    when "search"
      return { error: "resource_uri used as search query" } unless resource_uri

      results = manager.search_resources(resource_uri)
      {
        query: resource_uri,
        results_count: results.length,
        results: results
      }

    else
      { error: "Unknown operation: #{operation}" }
    end
  rescue => e
    { error: "MCP operation failed: #{e.message}" }
  end
end
```

## Prompt Templates

MCP supports prompt templates for common operations:

```ruby
class MCPPromptManager
  def initialize
    @clients = MCP_CLIENTS
  end

  def list_prompts
    prompts = {}

    @clients.each do |name, client|
      begin
        client_prompts = client.list_prompts
        prompts[name] = client_prompts
      rescue => e
        Rails.logger.error("Failed to list prompts from #{name}: #{e.message}")
      end
    end

    prompts
  end

  def get_prompt(client_name, prompt_name, arguments = {})
    client = @clients[client_name]
    return nil unless client

    client.get_prompt(prompt_name, arguments)
  end
end

class MCPPromptTool < RubyLLM::Tool
  description "Execute MCP prompt templates"

  param :client_name, desc: "MCP client to use"
  param :prompt_name, desc: "Name of prompt template"
  param :arguments, desc: "Arguments for prompt template", type: :object, required: false

  def execute(client_name:, prompt_name:, arguments: {})
    manager = MCPPromptManager.new

    prompt = manager.get_prompt(client_name.to_sym, prompt_name, arguments)

    if prompt
      {
        prompt_name: prompt_name,
        client: client_name,
        messages: prompt.messages,
        arguments: arguments
      }
    else
      { error: "Prompt not found: #{prompt_name}" }
    end
  rescue => e
    { error: "Failed to get prompt: #{e.message}" }
  end
end
```

## Error Handling and Reliability

### Connection Management

```ruby
class RobustMCPClient
  def initialize(config)
    @config = config
    @client = nil
    @connection_attempts = 0
    @max_attempts = 3
  end

  def ensure_connection
    return @client if @client && @client.connected?

    @connection_attempts += 1

    if @connection_attempts > @max_attempts
      raise "Failed to connect to MCP server after #{@max_attempts} attempts"
    end

    begin
      @client = RubyLLM::MCP.client(@config)
      @connection_attempts = 0 # Reset on successful connection
      @client
    rescue => e
      Rails.logger.error("MCP connection attempt #{@connection_attempts} failed: #{e.message}")

      if @connection_attempts < @max_attempts
        sleep(2 ** @connection_attempts) # Exponential backoff
        retry
      else
        raise e
      end
    end
  end

  def call_tool(name, arguments)
    ensure_connection.call_tool(name, arguments)
  rescue => e
    # Reset connection on error and try once more
    @client = nil
    @connection_attempts = 0

    begin
      ensure_connection.call_tool(name, arguments)
    rescue => retry_error
      Rails.logger.error("MCP tool call failed after retry: #{retry_error.message}")
      raise retry_error
    end
  end
end
```

### Graceful Degradation

```ruby
class FallbackMCPTool < RubyLLM::Tool
  description "Tool with MCP fallback to local implementation"

  param :operation, desc: "Operation to perform"

  def execute(operation:)
    # Try MCP first
    begin
      mcp_result = call_mcp_operation(operation)
      return mcp_result if mcp_result
    rescue => e
      Rails.logger.warn("MCP operation failed, falling back to local: #{e.message}")
    end

    # Fallback to local implementation
    local_operation(operation)
  end

  private

  def call_mcp_operation(operation)
    client = MCP_CLIENTS[:primary]
    client.call_tool("advanced_#{operation}", { operation: operation })
  rescue => e
    Rails.logger.error("MCP call failed: #{e.message}")
    nil
  end

  def local_operation(operation)
    case operation
    when "weather"
      # Local weather implementation
      { result: "Local weather data", source: "local" }
    when "calculate"
      # Local calculation
      { result: "Local calculation", source: "local" }
    else
      { error: "Operation not available locally", operation: operation }
    end
  end
end
```

## Testing MCP Integration

### Mocking MCP Clients

```ruby
# test/support/mcp_test_helper.rb
module MCPTestHelper
  def mock_mcp_client(name, tools: [], resources: [], prompts: [])
    client = double("MCP Client #{name}")

    allow(client).to receive(:list_tools).and_return(tools)
    allow(client).to receive(:list_resources).and_return(resources)
    allow(client).to receive(:list_prompts).and_return(prompts)

    tools.each do |tool|
      allow(client).to receive(:call_tool)
        .with(tool.name, anything)
        .and_return(mock_tool_result)
    end

    client
  end

  def mock_tool_result(content = "Mock result", error: false)
    result = double("MCP Tool Result")
    allow(result).to receive(:is_error).and_return(error)
    allow(result).to receive(:content).and_return(content)
    allow(result).to receive(:content_type).and_return("text/plain")
    result
  end
end

# test/services/mcp_service_test.rb
class MCPServiceTest < ActiveSupport::TestCase
  include MCPTestHelper

  def setup
    @mock_tool = double("MCP Tool", name: "test_tool", description: "Test tool")
    @mock_client = mock_mcp_client("test", tools: [@mock_tool])

    # Stub the MCP_CLIENTS constant
    stub_const("MCP_CLIENTS", { test: @mock_client })
  end

  test "creates chat with MCP tools" do
    service = DynamicMCPChat.new(users(:admin))
    chat = service.create_chat

    # Verify tools were registered
    assert_not_nil chat
  end

  test "handles MCP client failures gracefully" do
    allow(@mock_client).to receive(:list_tools).and_raise("Connection failed")

    service = DynamicMCPChat.new(users(:admin))

    # Should not raise exception
    assert_nothing_raised do
      chat = service.create_chat
    end
  end
end
```

## Best Practices

### Security Considerations

```ruby
class SecureMCPSetup
  def self.configure
    # Validate MCP server certificates
    configure_ssl_verification

    # Implement authentication
    configure_authentication

    # Set up access controls
    configure_access_controls
  end

  private

  def self.configure_ssl_verification
    # Only connect to verified MCP servers in production
    if Rails.env.production?
      RubyLLM::MCP.configure do |config|
        config.verify_ssl = true
        config.ca_file = Rails.root.join("config/ca-certificates.pem")
      end
    end
  end

  def self.configure_authentication
    # Use environment-specific authentication
    auth_config = {
      development: { token: "dev-token" },
      production: { token: Rails.application.credentials.mcp_production_token }
    }

    RubyLLM::MCP.configure do |config|
      config.auth = auth_config[Rails.env.to_sym]
    end
  end

  def self.configure_access_controls
    # Implement user-based access controls
    MCPAccessControl.setup_user_permissions
  end
end
```

### Performance Optimization

- **Connection pooling** - Reuse MCP connections when possible
- **Caching** - Cache MCP tool and resource listings
- **Timeout management** - Set appropriate timeouts for MCP operations
- **Graceful degradation** - Always provide fallback options

## Next Steps

- Review [Tool Basics](tools-basics.md) - foundational concepts and patterns
- Learn about [Callbacks](tools-callbacks.md) - monitoring MCP tool usage
- Explore [Rich Content](tools-rich-content.md) - handling complex MCP resource types
- Understand [Execution Flow](tools-execution-flow.md) - managing MCP tool execution patterns
