# RubyLLM Model Registry

The RubyLLM Model Registry is a powerful feature that provides comprehensive metadata about available AI models across different providers. This centralized system makes it easy to discover, filter, and use various AI models in your application.

## Overview

The Model Registry maintains a comprehensive database of AI models with rich metadata including:
- Provider information (OpenAI, Anthropic, Google, etc.)
- Model capabilities (chat, embeddings, vision, function calling)
- Technical specifications (context windows, token limits)
- Pricing information
- Model families and relationships

## Basic Usage

### Discovering Available Models

```ruby
# Get all available models
all_models = RubyLLM.models.all

# Get only chat-capable models
chat_models = RubyLLM.models.chat_models

# Filter by provider
openai_models = RubyLLM.models.by_provider(:openai)
anthropic_models = RubyLLM.models.by_provider(:anthropic)
```

### Finding Specific Models

```ruby
# Find a model by ID or alias
gpt4_model = RubyLLM.models.find('gpt-4.1')
claude_model = RubyLLM.models.find('claude-3.7-sonnet')

# Check if model exists
if gpt4_model
  puts "Model: #{gpt4_model.id}"
  puts "Provider: #{gpt4_model.provider}"
  puts "Context window: #{gpt4_model.context_window}"
end
```

## Model Registry API

### Available Methods

| Method | Description | Returns |
|--------|-------------|---------|
| `RubyLLM.models.all` | Returns all registered models | Array of model objects |
| `RubyLLM.models.chat_models` | Returns only chat-capable models | Array of model objects |
| `RubyLLM.models.by_provider(provider)` | Filters models by provider | Array of model objects |
| `RubyLLM.models.find(model_id)` | Finds a specific model by ID or alias | Model object or nil |
| `RubyLLM.models.refresh!` | Updates registry from remote source | Boolean |

### Model Metadata Properties

Each model object includes these properties:

```ruby
model = RubyLLM.models.find('gpt-4.1')

model.id                # Unique model identifier
model.provider          # Provider (openai, anthropic, etc.)
model.type             # Model type (chat, embedding, etc.)
model.context_window   # Maximum input tokens
model.max_tokens       # Maximum output tokens
model.vision_support   # Boolean - supports images?
model.function_support # Boolean - supports function calling?
model.pricing          # Cost per token information
model.family          # Model family grouping
```

## Practical Examples

### Example 1: List All Chat Models with Vision Support

```ruby
vision_models = RubyLLM.models.chat_models.select do |model|
  model.vision_support == true
end

vision_models.each do |model|
  puts "#{model.id} (#{model.provider}) - Context: #{model.context_window}"
end
```

### Example 2: Finding the Best Model for Your Needs

```ruby
# Find OpenAI models with large context windows
large_context_models = RubyLLM.models
  .by_provider(:openai)
  .select { |m| m.context_window >= 128000 }
  .sort_by(&:context_window)
  .reverse

# Use the model with largest context
if large_context_models.any?
  best_model = large_context_models.first
  chat = RubyLLM.chat(model: best_model.id)
end
```

### Example 3: Working with Model Capabilities

```ruby
# Find models that support function calling
function_models = RubyLLM.models.all.select(&:function_support)

# Find models that support both vision and functions
advanced_models = RubyLLM.models.all.select do |model|
  model.vision_support && model.function_support
end
```

## Advanced Usage

### Refreshing the Model Registry

The model registry is cached locally in `lib/ruby_llm/models.json`. To update it with the latest model information:

```ruby
# Refresh the registry from remote source
RubyLLM.models.refresh!

# This updates the local cache with:
# - New models
# - Updated capabilities
# - Current pricing
# - Deprecated model notices
```

### Using Custom Endpoints

For Azure OpenAI or private deployments:

```ruby
# Configure custom endpoint
RubyLLM.configure do |config|
  config.openai_api_key = ENV['AZURE_OPENAI_KEY']
  config.openai_api_base = "https://your-resource.openai.azure.com"
end

# Models will now route through your custom endpoint
chat = RubyLLM.chat(model: 'gpt-4')
```

### Working with Unlisted Models

If you need to use a model not in the registry:

```ruby
# Force use of an unlisted model
chat = RubyLLM.chat(
  model: 'my-custom-model',
  provider: :openai,
  assume_model_exists: true
)

# This bypasses registry validation
response = chat.complete(messages: [{role: 'user', content: 'Hello'}])
```

## Integration with Chat Models

In your Rails models using `acts_as_chat`:

```ruby
class Chat < ApplicationRecord
  acts_as_chat

  # Use registry to validate model selection
  validates :model_id, inclusion: {
    in: -> { RubyLLM.models.chat_models.map(&:id) },
    message: "must be a valid chat model"
  }

  # Helper to get model info
  def model_info
    @model_info ||= RubyLLM.models.find(model_id)
  end

  def supports_vision?
    model_info&.vision_support || false
  end

  def max_context_size
    model_info&.context_window || 4096
  end
end
```

## Building Model Selection UI

Use the registry to populate model selection dropdowns:

```ruby
# In your controller
def available_models
  @available_models ||= RubyLLM.models.chat_models.map do |model|
    {
      model_id: model.id,
      label: "#{model.id} (#{model.provider.capitalize})",
      context_window: model.context_window,
      supports_vision: model.vision_support,
      supports_functions: model.function_support
    }
  end
end
```

## Performance Considerations

1. **Caching**: The registry is loaded once and cached in memory
2. **Filtering**: All filtering operations work on cached data (no network calls)
3. **Refresh**: Only `refresh!` makes network calls
4. **Startup**: Registry loads on first access, not at application boot

## Best Practices

1. **Regular Updates**: Refresh the registry periodically to get new models and updated capabilities
2. **Capability Checking**: Always verify model capabilities before using advanced features
3. **Fallback Logic**: Implement fallbacks for when preferred models aren't available
4. **Provider Diversity**: Consider models from different providers for redundancy
5. **Cost Awareness**: Use pricing information to optimize model selection

## Troubleshooting

### Registry Not Loading

```ruby
# Check if registry is accessible
begin
  models = RubyLLM.models.all
  puts "Registry loaded: #{models.count} models"
rescue => e
  puts "Registry error: #{e.message}"
end
```

### Model Not Found

```ruby
# Debug model lookup
model_id = 'gpt-4'
model = RubyLLM.models.find(model_id)

if model.nil?
  # Try refreshing registry
  RubyLLM.models.refresh!
  model = RubyLLM.models.find(model_id)

  if model.nil?
    # Model genuinely not in registry
    puts "Model #{model_id} not found in registry"
    puts "Available models: #{RubyLLM.models.all.map(&:id).join(', ')}"
  end
end
```

## See Also

- [Configuration Guide](./configuration.md) - Setting up providers and API keys
- [Chat Models](./chat-models.md) - Using the chat interface
- [Provider Setup](./providers.md) - Configuring different AI providers
- [Advanced Features](./advanced-features.md) - Vision, functions, and streaming