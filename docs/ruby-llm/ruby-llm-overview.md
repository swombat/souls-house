# RubyLLM Documentation

> Historical reference only. souls.house no longer depends on RubyLLM or runs
> inline agents. See the [retirement runbook](../plans/260905-01b-rubyllm-removal-implementation-checkpoint.md)
> for the current harness-only architecture and utility inference.

RubyLLM is a unified Ruby API for interacting with multiple AI providers and models, designed to simplify AI integration in Ruby applications. This documentation provides comprehensive guidance for using RubyLLM effectively in your projects.

## What is RubyLLM?

RubyLLM provides "One beautiful Ruby API for GPT, Claude, Gemini, and more." It eliminates the complexity of managing multiple AI provider clients by offering a single, consistent interface across different AI models and capabilities.

### Key Features

- **Multi-Provider Support**: Works with OpenAI, Anthropic Claude, Google Gemini, and 500+ other models
- **Unified Interface**: Consistent API across all providers and models
- **Lightweight**: Only three dependencies
- **Multiple AI Capabilities**:
  - Chat interactions and conversations
  - Vision analysis and image understanding
  - Audio transcription
  - Document processing
  - Image generation
  - Text embeddings
  - Content moderation
  - AI tool integration

## Quick Start

### Installation

Add RubyLLM to your Gemfile:

```ruby
gem 'ruby_llm'
```

### Configuration

Configure your API keys:

```ruby
RubyLLM.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.anthropic_api_key = ENV['ANTHROPIC_API_KEY']
  config.google_api_key = ENV['GOOGLE_API_KEY']
end
```

### Basic Usage

```ruby
# Simple chat interaction
chat = RubyLLM.chat
response = chat.ask "What's the best way to learn Ruby?"

# Analyze files
response = chat.ask "What's in this image?", with: "conference_photo.jpg"

# Generate images
RubyLLM.paint "a sunset over mountains in watercolor style"

# Get embeddings for semantic search
embeddings = RubyLLM.embeddings.embed("Ruby programming tutorial")
```

## Core Concepts

### Chat Interface

The primary interface for conversational AI interactions:

```ruby
# Create a chat instance
chat = RubyLLM.chat

# Basic question
answer = chat.ask("Explain Ruby blocks")

# With specific model
chat = RubyLLM.chat(model: 'claude-3-sonnet')

# With system prompt
chat = RubyLLM.chat
chat.system_prompt = "You are a Ruby expert"
```

### Model Selection

RubyLLM supports dynamic model selection based on task requirements:

```ruby
# Different models for different tasks
code_chat = RubyLLM.chat(model: 'claude-3-sonnet')  # Great for code
creative_chat = RubyLLM.chat(model: 'gpt-4')        # Great for creative tasks
factual_chat = RubyLLM.chat(model: 'gemini-pro')    # Great for factual queries
```

### Tools and Function Calling

Enable AI agents to use external tools and functions:

```ruby
chat = RubyLLM.chat
chat.tools = [
  {
    name: 'search_web',
    description: 'Search the web for information',
    parameters: {
      type: 'object',
      properties: {
        query: { type: 'string' }
      }
    }
  }
]
```

### Structured Output

Get reliable, structured responses using JSON schemas:

```ruby
schema = {
  type: 'object',
  properties: {
    sentiment: { type: 'string', enum: ['positive', 'negative', 'neutral'] },
    confidence: { type: 'number', minimum: 0, maximum: 1 },
    keywords: { type: 'array', items: { type: 'string' } }
  },
  required: ['sentiment', 'confidence']
}

result = chat.ask("Analyze the sentiment of this text", schema: schema)
parsed_result = JSON.parse(result)
```

## Documentation Index

### Core Documentation

1. **[Agentic Workflows](agentic-workflows.md)** - Advanced patterns for building AI agent systems
   - Multi-agent systems and coordination
   - State management and memory
   - Workflow orchestration
   - Decision making and conditional logic
   - Complex workflow examples
   - Performance optimization

2. **[Model Registry](model-registry.md)** - Comprehensive model discovery and management
   - Discovering available models
   - Filtering by provider and capabilities
   - Model metadata and specifications
   - Custom endpoints and unlisted models
   - Integration with chat models

### Advanced Topics

3. **Integration Patterns** (Coming Soon)
   - Rails application integration
   - Background job processing
   - Real-time streaming responses
   - Caching strategies

4. **Security and Best Practices** (Coming Soon)
   - API key management
   - Input sanitization
   - Output validation
   - Privacy considerations

## Architecture Overview

RubyLLM follows a modular architecture that abstracts away provider-specific implementations:

```
┌─────────────────────────────────────┐
│           Your Application          │
├─────────────────────────────────────┤
│            RubyLLM API              │
├─────────────────────────────────────┤
│         Provider Adapters           │
├─────────────────────────────────────┤
│  OpenAI │ Anthropic │ Google │ ... │
└─────────────────────────────────────┘
```

### Key Components

- **Chat Interface**: Primary conversational API
- **Model Registry**: Manages 500+ available models
- **Provider Adapters**: Handle provider-specific implementations
- **Tool System**: Enables function calling and external integrations
- **Streaming Support**: Real-time response processing
- **Embedding Engine**: Vector generation for semantic search

## Getting Started Guide

### 1. Basic Chat Application

```ruby
# config/initializers/ruby_llm.rb
RubyLLM.configure do |config|
  config.openai_api_key = Rails.application.credentials.openai_api_key
end

# app/controllers/chat_controller.rb
class ChatController < ApplicationController
  def create
    chat = RubyLLM.chat
    response = chat.ask(params[:message])

    render json: { response: response }
  end
end
```

### 2. Document Analysis Service

```ruby
class DocumentAnalyzer
  def initialize
    @chat = RubyLLM.chat(model: 'claude-3-sonnet')
    @chat.system_prompt = "You are an expert document analyzer."
  end

  def analyze(file_path)
    @chat.ask("Analyze this document and provide key insights:", with: file_path)
  end

  def summarize(file_path)
    @chat.ask("Provide a concise summary of this document:", with: file_path)
  end

  def extract_data(file_path, schema)
    prompt = "Extract structured data from this document according to the provided schema."
    @chat.ask(prompt, with: file_path, schema: schema)
  end
end
```

### 3. Semantic Search with Embeddings

```ruby
class SemanticSearch
  def initialize
    @embeddings = RubyLLM.embeddings
  end

  def index_documents(documents)
    documents.each do |doc|
      embedding = @embeddings.embed(doc.content)
      doc.update!(embedding: embedding)
    end
  end

  def search(query, limit: 5)
    query_embedding = @embeddings.embed(query)

    # Using PostgreSQL with pgvector
    Document.order(
      Arel.sql("embedding <-> '#{query_embedding}' ASC")
    ).limit(limit)
  end
end
```

## Performance Considerations

### Caching

Implement caching for frequently requested content:

```ruby
class CachedChat
  def initialize
    @chat = RubyLLM.chat
    @cache = Rails.cache
  end

  def ask(query, cache_duration: 1.hour)
    cache_key = "chat_response:#{Digest::SHA256.hexdigest(query)}"

    @cache.fetch(cache_key, expires_in: cache_duration) do
      @chat.ask(query)
    end
  end
end
```

### Async Processing

Handle long-running tasks asynchronously:

```ruby
class AsyncChatJob < ApplicationJob
  def perform(user_id, message)
    chat = RubyLLM.chat
    response = chat.ask(message)

    # Broadcast response via ActionCable
    ActionCable.server.broadcast(
      "chat_channel_#{user_id}",
      { response: response }
    )
  end
end
```

## Common Use Cases

### 1. Content Generation

```ruby
# Blog post generator
blog_generator = RubyLLM.chat(model: 'gpt-4')
blog_generator.system_prompt = "You are a professional blog writer."

post = blog_generator.ask("Write a blog post about Ruby on Rails best practices")
```

### 2. Code Review Assistant

```ruby
# Code review helper
code_reviewer = RubyLLM.chat(model: 'claude-3-sonnet')
code_reviewer.system_prompt = "You are a senior Ruby developer providing code reviews."

review = code_reviewer.ask("Review this Ruby code for best practices:", with: "app/models/user.rb")
```

### 3. Data Analysis

```ruby
# Data insights generator
analyzer = RubyLLM.chat
insights = analyzer.ask("Analyze this CSV data and provide insights:", with: "sales_data.csv")
```

### 4. Customer Support

```ruby
# Support bot
support_bot = RubyLLM.chat
support_bot.system_prompt = "You are a helpful customer support assistant."

response = support_bot.ask("How do I reset my password?")
```

## Error Handling

Implement robust error handling for production applications:

```ruby
class RobustChat
  def initialize
    @chat = RubyLLM.chat
  end

  def safe_ask(query, max_retries: 3)
    retries = 0

    begin
      @chat.ask(query)
    rescue => e
      retries += 1

      if retries <= max_retries
        sleep(2 ** retries) # Exponential backoff
        retry
      else
        Rails.logger.error "Chat request failed after #{max_retries} retries: #{e.message}"
        "I'm having trouble processing your request right now. Please try again later."
      end
    end
  end
end
```

## Testing

Test your RubyLLM integrations effectively:

```ruby
# test/support/ruby_llm_test_helper.rb
module RubyLLMTestHelper
  def stub_ruby_llm_response(response)
    chat_double = double('RubyLLM::Chat')
    allow(chat_double).to receive(:ask).and_return(response)
    allow(RubyLLM).to receive(:chat).and_return(chat_double)
  end
end

# test/models/document_analyzer_test.rb
class DocumentAnalyzerTest < ActiveSupport::TestCase
  include RubyLLMTestHelper

  test "analyzes document content" do
    stub_ruby_llm_response("This document contains financial data...")

    analyzer = DocumentAnalyzer.new
    result = analyzer.analyze("test_document.pdf")

    assert_includes result, "financial data"
  end
end
```

## Next Steps

1. **Start Simple**: Begin with basic chat interactions
2. **Explore Models**: Try different models for different use cases
3. **Add Tools**: Implement function calling for external integrations
4. **Build Agents**: Create sophisticated agentic workflows
5. **Optimize**: Implement caching and async processing
6. **Monitor**: Track performance and costs

## Resources

- **Official Website**: [rubyllm.com](https://rubyllm.com)
- **GitHub Repository**: [ruby_llm](https://github.com/carminepaolino/ruby_llm)
- **Creator**: Carmine Paolino ([@carminepaolino](https://twitter.com/carminepaolino))
- **Chat with Work**: [chatwithwork.com](https://chatwithwork.com) - Real-world application built with RubyLLM

## Contributing

RubyLLM is actively developed and welcomes contributions. Check the GitHub repository for contribution guidelines and current issues.

---

*This documentation is part of the HelixKit project and provides guidance for integrating RubyLLM into Rails applications effectively.*
