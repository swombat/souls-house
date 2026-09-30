# Prompt System Documentation

The Prompt system provides a structured way to interact with AI models through OpenRouter API. It supports template-based prompts, streaming responses, and automatic storage of results to database models.

## Overview

The `Prompt` class (`app/prompts/prompt.rb`) is a flexible system for:
- Creating reusable AI prompt templates with ERB
- Executing prompts with different response formats (string, JSON, streaming)
- Automatically saving responses to ActiveRecord models
- Supporting multiple AI models through OpenRouter

## Basic Usage

### Creating a Simple Prompt

```ruby
# Using the base Prompt class directly
prompt = Prompt.new(model: "openai/gpt-4o", template: "summarize_text")

# Execute and get a string response
response = prompt.execute_to_string

# Execute with streaming
prompt.execute_to_string do |incremental_response, delta|
  print delta # Print each chunk as it arrives
end
```

### Available Models

The Prompt class includes predefined model constants:

```ruby
Prompt::DEFAULT_MODEL  # "openai/gpt-5"
Prompt::SMART_MODEL    # "openai/gpt-5"
Prompt::LIGHT_MODEL    # "openai/gpt-5-mini"
Prompt::CHAT_MODEL     # "openai/gpt-5-chat"
```

You can also use model shortcuts:
- `"4o"` → `"openai/chatgpt-4o-latest"`
- `"o1"` → `"openai/o1"`
- `"4o-mini"` → `"openai/gpt-4o-mini"`

## Template-Based Prompts

### File Structure

For a template-based prompt, create a directory under `app/prompts/` with the template name containing two ERB files:

```
app/prompts/
└── summarize_text/
    ├── system.prompt.erb  # System prompt (optional)
    └── user.prompt.erb    # User prompt (optional)
```

### Template Files

**system.prompt.erb:**
```erb
You are a helpful assistant that summarizes text concisely.
Maximum length: <%= max_words %> words.
```

**user.prompt.erb:**
```erb
Please summarize the following text:

<%= text %>

Focus on the key points and main ideas.
```

### Using Templates

```ruby
# Create prompt with template
prompt = Prompt.new(template: "summarize_text")

# Render with variables
params = prompt.render(
  text: "Long article content here...",
  max_words: 100
)
# Returns: { system: "...", user: "...", model: "openai/gpt-5" }

# Execute with template variables
response = prompt.execute_to_string
```

## Creating Custom Prompt Classes

You can create specialized prompt classes by inheriting from `Prompt`:

```ruby
class SummarizePrompt < Prompt
  def initialize(text:, max_words: 100)
    super(model: Prompt::LIGHT_MODEL, template: "summarize")

    @args = {
      text: text,
      max_words: max_words
    }
  end

  def render(**args)
    args = @args if args.empty?
    super(args)
  end
end

# Usage
prompt = SummarizePrompt.new(
  text: article.content,
  max_words: 150
)
summary = prompt.execute_to_string
```

### Without Templates

You can also override the `render` method to provide prompts directly:

```ruby
class CustomPrompt < Prompt
  def initialize(question:)
    super(model: "openai/gpt-4o", template: nil)
    @question = question
  end

  def render(**args)
    {
      model: @model,
      system: "You are a helpful assistant.",
      user: @question
    }
  end
end
```

## Execution Methods

### 1. Execute to String

Returns the complete response as a string:

```ruby
# Simple execution
response = prompt.execute_to_string

# With streaming callback
prompt.execute_to_string do |incremental_response, delta|
  # incremental_response: full response so far
  # delta: new text chunk just received
  print delta
end
```

### 2. Execute to JSON

For prompts that return JSON data:

```ruby
# Execute and parse JSON response
response = prompt.execute_to_json

# Stream multiple JSON objects
prompt.execute_to_json do |json_object|
  # Called for each JSON object in the response
  process_json_object(json_object)
end
```

### 3. Execute with Output Storage

Automatically save responses to an ActiveRecord model:

```ruby
# Create a PromptOutput record
prompt_output = PromptOutput.create(account: current_account)

# Execute and save to model
response = prompt.execute(
  output_class: "PromptOutput",
  output_id: prompt_output.id,
  output_property: :output      # Field to store response
)

# For JSON responses
response = prompt.execute(
  output_class: "PromptOutput",
  output_id: prompt_output.id,
  output_property: :output_json, # JSON field
  json: true                     # Parse as JSON
)
```

#### Streaming to Model Properties

When using `execute` with an output model, the response is automatically streamed and saved to the database:

- **Text responses**: Updates the specified property with each chunk
- **JSON responses**:
  - If property is an Array: Appends each JSON object
  - If property is a Hash: Merges new data

## Conversation Support

The Prompt system supports conversation-style interactions:

```ruby
# Create a conversation prompt
prompt = Prompt.new(
  model: "openai/gpt-5",
  template: "conversation"  # Special template type
)

# Render with conversation object
params = prompt.render(
  conversation: chat  # Must have .messages association
)

# The conversation's messages are formatted as:
# {
#   messages: [
#     { role: "user", content: "Hello" },
#     { role: "assistant", content: "Hi there!" },
#     ...
#   ]
# }
```

However, if a conversation is the goal, please use the RubyLLM approach instead (see `docs/stack/ruby-llm.md`).

## PromptOutput Model

The `PromptOutput` model is provided for storing AI responses:

```ruby
class PromptOutput < ApplicationRecord
  belongs_to :account, optional: true

  # Fields:
  # - prompt_key: String identifier for the prompt
  # - output: Text field for string responses
  # - output_json: JSONB field for structured data
  # - timestamps
end
```

## Error Handling

The Prompt class includes automatic retry logic:

- **Rate limiting**: Exponential backoff up to 6 attempts
- **Timeouts**: Retries up to 3 times
- **Other errors**: Raised immediately

## Complete Example

Here's a complete example of creating and using a custom prompt:

### 1. Create Template Files

`app/prompts/analyze_code/system.prompt.erb`:
```erb
You are an expert code reviewer. Analyze the provided code for:
- Security issues
- Performance problems
- Best practices
Language: <%= language %>
```

`app/prompts/analyze_code/user.prompt.erb`:
```erb
Please review this code:

```<%= language %>
<%= code %>
```

Provide specific suggestions for improvement.
```

### 2. Create Prompt Class

`app/prompts/code_analysis_prompt.rb`:
```ruby
class CodeAnalysisPrompt < Prompt
  def initialize(code:, language: "ruby")
    super(model: Prompt::SMART_MODEL, template: "analyze_code")

    @args = {
      code: code,
      language: language
    }
  end

  def analyze
    execute_to_string
  end

  def analyze_and_save(output_id)
    execute(
      output_class: "PromptOutput",
      output_id: output_id,
      output_property: :output
    )
  end
end
```

### 3. Use in Controller

```ruby
class CodeReviewsController < ApplicationController
  def create
    prompt = CodeAnalysisPrompt.new(
      code: params[:code],
      language: params[:language]
    )

    # Create output record
    output = PromptOutput.create(
      account: current_account,
      prompt_key: "code_review_#{SecureRandom.hex(4)}"
    )

    # Execute and stream to database
    prompt.analyze_and_save(output.id)

    redirect_to code_review_path(output)
  end
end
```

## Testing Prompts

The test suite uses VCR to record and replay API responses:

```ruby
require "test_helper"
require "support/vcr_setup"

class MyPromptTest < ActiveSupport::TestCase
  test "executes custom prompt" do
    VCR.use_cassette("prompt/my_custom_prompt") do
      prompt = MyPrompt.new(input: "test data")
      response = prompt.execute_to_string

      assert response.present?
      assert_includes response, "expected content"
    end
  end
end
```

## Best Practices

1. **Use Templates for Reusability**: Create template directories for prompts you'll use multiple times
2. **Choose the Right Model**: Use `LIGHT_MODEL` for simple tasks, `SMART_MODEL` for complex reasoning
3. **Stream for Long Responses**: Use streaming callbacks for better UX with long responses
4. **Store Important Results**: Use `execute` with output models to persist AI responses
5. **Handle Errors Gracefully**: The built-in retry logic handles most transient errors
6. **Test with VCR**: Record API responses in tests to avoid hitting the API repeatedly

## API Integration

The Prompt system uses the `OpenRouterApi` class (`app/api/open_router_api.rb`) to communicate with OpenRouter. This handles:
- Authentication with API keys
- Request formatting
- Response streaming
- Error handling

The API configuration is managed through Rails credentials and environment variables.