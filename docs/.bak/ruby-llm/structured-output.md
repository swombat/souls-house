# RubyLLM Structured Output

## Version Information
- Documentation version: Latest (v1.7.0+)
- Source: https://rubyllm.com/tools/ and https://rubyllm.com/chat/
- Fetched: 2025-10-05

## Key Concepts

- **Schema Definition**: Define strict output structures using `RubyLLM::Schema`
- **Type Coercion**: Automatic conversion of AI responses to expected data types
- **JSON Responses**: Guaranteed JSON output with validation
- **Provider Support**: Works across different AI providers (OpenAI, Anthropic, etc.)
- **Validation**: Built-in validation and error handling for structured data

## Implementation Guide

### 1. Basic Schema Definition

```ruby
# Define a schema class
class PersonSchema < RubyLLM::Schema
  string :name, required: true
  integer :age, required: true
  string :email, required: false
  boolean :active, default: true
end

# Use schema with chat
chat = RubyLLM.chat.with_schema(PersonSchema)
response = chat.ask("Generate a person named John who is 30 years old")

# Access structured data
puts response.name    # "John"
puts response.age     # 30
puts response.email   # nil (optional field)
puts response.active  # true (default value)
```

### 2. Complex Schema Structures

```ruby
# Nested schemas
class AddressSchema < RubyLLM::Schema
  string :street, required: true
  string :city, required: true
  string :state, required: true
  string :zip_code, required: true
end

class UserSchema < RubyLLM::Schema
  string :name, required: true
  integer :age, required: true
  object :address, schema: AddressSchema, required: true
  array :hobbies, items: :string, required: false
  enum :status, values: ['active', 'inactive', 'pending'], default: 'active'
end

# Use nested schema
chat = RubyLLM.chat.with_schema(UserSchema)
response = chat.ask("Create a user profile for Alice in San Francisco")

puts response.name                    # "Alice"
puts response.address.city           # "San Francisco"
puts response.hobbies                # ["reading", "hiking"]
puts response.status                 # "active"
```

### 3. Array and Collection Schemas

```ruby
# Schema for array of objects
class ProductSchema < RubyLLM::Schema
  string :name, required: true
  number :price, required: true
  string :category, required: true
  boolean :in_stock, default: true
end

class ProductListSchema < RubyLLM::Schema
  array :products, items: ProductSchema, required: true
  integer :total_count, required: true
end

# Generate structured list
chat = RubyLLM.chat.with_schema(ProductListSchema)
response = chat.ask("Generate 3 electronics products with prices")

response.products.each do |product|
  puts "#{product.name}: $#{product.price}"
end
puts "Total: #{response.total_count}"
```

### 4. Rails Integration with Schemas

```ruby
# app/schemas/chat_summary_schema.rb
class ChatSummarySchema < RubyLLM::Schema
  string :title, required: true
  string :summary, required: true
  array :key_points, items: :string, required: true
  integer :message_count, required: true
  enum :sentiment, values: ['positive', 'negative', 'neutral'], required: true
end

# app/services/chat_analysis_service.rb
class ChatAnalysisService
  def initialize(chat)
    @chat = chat
  end

  def generate_summary
    messages_text = @chat.messages.pluck(:content).join("\n")

    chat = RubyLLM.chat.with_schema(ChatSummarySchema)
    response = chat.ask(
      "Analyze this conversation and provide a summary:\n#{messages_text}"
    )

    # Store structured result
    @chat.update!(
      title: response.title,
      summary: response.summary,
      sentiment: response.sentiment
    )

    response
  rescue RubyLLM::Error => e
    Rails.logger.error "Schema validation failed: #{e.message}"
    raise AnalysisError, "Failed to generate chat summary"
  end
end
```

### 5. Dynamic Schema Generation

```ruby
# Generate schema from Rails model
class UserProfileSchema < RubyLLM::Schema
  # Automatically generate from User model attributes
  def self.from_model(model_class)
    schema = Class.new(RubyLLM::Schema)

    model_class.columns.each do |column|
      case column.type
      when :string, :text
        schema.string column.name.to_sym, required: !column.null
      when :integer, :bigint
        schema.integer column.name.to_sym, required: !column.null
      when :boolean
        schema.boolean column.name.to_sym, required: !column.null
      when :decimal, :float
        schema.number column.name.to_sym, required: !column.null
      end
    end

    schema
  end
end

# Use dynamic schema
user_schema = UserProfileSchema.from_model(User)
chat = RubyLLM.chat.with_schema(user_schema)
```

## API Reference

### Schema Types

```ruby
class ExampleSchema < RubyLLM::Schema
  # Basic types
  string :name, required: true, default: "Unknown"
  integer :count, required: false
  number :price, required: true  # Float/decimal
  boolean :active, default: false

  # Collections
  array :tags, items: :string, required: false
  array :products, items: ProductSchema, required: true

  # Objects
  object :metadata, schema: MetadataSchema, required: false

  # Enumerations
  enum :status, values: ['draft', 'published', 'archived'], required: true

  # Dates (string format)
  string :created_at, format: :datetime, required: false
end
```

### Schema Options

| Option | Description | Example |
|--------|-------------|---------|
| `required` | Field is mandatory | `required: true` |
| `default` | Default value if not provided | `default: "N/A"` |
| `description` | Field description for AI | `description: "User's full name"` |
| `format` | String format validation | `format: :email` |
| `items` | Array item type | `items: :string` or `items: Schema` |
| `schema` | Nested object schema | `schema: AddressSchema` |
| `values` | Enum allowed values | `values: ['small', 'medium', 'large']` |

### Chat Methods with Schemas

```ruby
# Apply schema to chat
chat = RubyLLM.chat.with_schema(MySchema)

# One-time schema usage
response = RubyLLM.chat(schema: MySchema).ask("Generate data")

# Rails persistent chat with schema
chat_record = Chat.create!(schema_class: 'MySchema')
response = chat_record.ask("Generate structured data")
```

## Code Examples

### E-commerce Product Generator

```ruby
class ProductSchema < RubyLLM::Schema
  string :name, required: true, description: "Product name"
  string :description, required: true, description: "Detailed product description"
  number :price, required: true, description: "Price in USD"
  string :category, required: true, description: "Product category"
  array :features, items: :string, required: true, description: "Key features list"
  boolean :featured, default: false, description: "Is this a featured product?"
  enum :availability, values: ['in_stock', 'out_of_stock', 'pre_order'], required: true
end

class ProductGeneratorService
  def initialize(category, price_range)
    @category = category
    @price_range = price_range
  end

  def generate_products(count = 5)
    chat = RubyLLM.chat.with_schema(ProductListSchema)

    prompt = """
    Generate #{count} #{@category} products with prices between $#{@price_range.min} and $#{@price_range.max}.
    Make them realistic and appealing for an e-commerce store.
    """

    response = chat.ask(prompt)

    # Convert to Rails models
    response.products.map do |product_data|
      Product.create!(
        name: product_data.name,
        description: product_data.description,
        price: product_data.price,
        category: product_data.category,
        features: product_data.features,
        featured: product_data.featured,
        availability: product_data.availability
      )
    end
  rescue RubyLLM::Error => e
    Rails.logger.error "Product generation failed: #{e.message}"
    []
  end
end
```

### Survey Response Analysis

```ruby
class SurveyResponseSchema < RubyLLM::Schema
  string :respondent_type, required: true, description: "Type of respondent"
  integer :satisfaction_score, required: true, description: "Satisfaction score 1-10"
  array :positive_aspects, items: :string, required: true
  array :negative_aspects, items: :string, required: true
  array :improvement_suggestions, items: :string, required: false
  enum :likelihood_to_recommend, values: ['very_likely', 'likely', 'neutral', 'unlikely', 'very_unlikely'], required: true
  boolean :would_purchase_again, required: true
end

class SurveyAnalysisController < ApplicationController
  def analyze
    @survey = Survey.find(params[:id])
    raw_responses = @survey.responses.pluck(:content)

    analyzed_responses = raw_responses.map do |response_text|
      analyze_single_response(response_text)
    end.compact

    @analysis = {
      total_responses: analyzed_responses.size,
      average_satisfaction: calculate_average_satisfaction(analyzed_responses),
      common_positives: extract_common_themes(analyzed_responses, :positive_aspects),
      common_negatives: extract_common_themes(analyzed_responses, :negative_aspects)
    }

    render :analysis
  end

  private

  def analyze_single_response(response_text)
    chat = RubyLLM.chat.with_schema(SurveyResponseSchema)

    prompt = """
    Analyze this survey response and extract structured data:

    #{response_text}

    Provide satisfaction score, positive/negative aspects, and recommendations.
    """

    chat.ask(prompt)
  rescue RubyLLM::Error => e
    Rails.logger.error "Response analysis failed: #{e.message}"
    nil
  end

  def calculate_average_satisfaction(responses)
    return 0 if responses.empty?
    responses.sum(&:satisfaction_score) / responses.size.to_f
  end

  def extract_common_themes(responses, field)
    all_themes = responses.flat_map { |r| r.send(field) }
    all_themes.tally.sort_by(&:last).reverse.first(5).to_h
  end
end
```

### Content Moderation Schema

```ruby
class ContentModerationSchema < RubyLLM::Schema
  boolean :is_appropriate, required: true, description: "Is content appropriate?"
  enum :content_type, values: ['text', 'spam', 'harassment', 'hate_speech', 'adult', 'violence'], required: true
  integer :confidence_score, required: true, description: "Confidence score 0-100"
  string :reason, required: false, description: "Reason if inappropriate"
  array :flagged_phrases, items: :string, required: false, description: "Specific problematic phrases"
  boolean :requires_human_review, default: false, description: "Needs human moderator review"
end

class ContentModerationService
  def initialize
    @chat = RubyLLM.chat.with_schema(ContentModerationSchema)
  end

  def moderate_content(content)
    prompt = """
    Analyze this content for appropriateness and safety:

    #{content}

    Check for spam, harassment, hate speech, adult content, violence, or other policy violations.
    Provide confidence score and specific reasons if inappropriate.
    """

    result = @chat.ask(prompt)

    # Take action based on moderation result
    if !result.is_appropriate
      handle_inappropriate_content(content, result)
    elsif result.requires_human_review
      queue_for_human_review(content, result)
    end

    result
  rescue RubyLLM::Error => e
    Rails.logger.error "Content moderation failed: #{e.message}"
    # Fail safe - flag for human review
    ContentModerationSchema.new(
      is_appropriate: false,
      content_type: 'text',
      confidence_score: 0,
      reason: "Moderation system error",
      requires_human_review: true
    )
  end

  private

  def handle_inappropriate_content(content, result)
    ContentModerationLog.create!(
      content: content,
      action: 'blocked',
      reason: result.reason,
      confidence: result.confidence_score,
      flagged_phrases: result.flagged_phrases
    )
  end

  def queue_for_human_review(content, result)
    ModerationQueue.create!(
      content: content,
      ai_assessment: result.to_h,
      priority: result.confidence_score < 50 ? 'high' : 'normal'
    )
  end
end
```

### Background Job with Schema

```ruby
class GenerateReportJob < ApplicationJob
  queue_as :reports

  class ReportSchema < RubyLLM::Schema
    string :title, required: true
    string :executive_summary, required: true
    array :key_findings, items: :string, required: true
    array :recommendations, items: :string, required: true
    object :metrics, schema: ReportMetricsSchema, required: true
    string :conclusion, required: true
  end

  class ReportMetricsSchema < RubyLLM::Schema
    integer :total_users, required: true
    number :growth_percentage, required: true
    integer :active_sessions, required: true
    number :revenue, required: true
  end

  def perform(report_id, data_params)
    report = Report.find(report_id)

    begin
      # Generate structured report
      chat = RubyLLM.chat.with_schema(ReportSchema)

      prompt = build_report_prompt(data_params)
      result = chat.ask(prompt)

      # Save structured data
      report.update!(
        title: result.title,
        content: {
          executive_summary: result.executive_summary,
          key_findings: result.key_findings,
          recommendations: result.recommendations,
          metrics: result.metrics.to_h,
          conclusion: result.conclusion
        },
        status: 'completed'
      )

      # Notify completion
      ReportMailer.report_ready(report).deliver_now

    rescue RubyLLM::Error => e
      report.update!(
        status: 'failed',
        error_message: e.message
      )

      Rails.logger.error "Report generation failed: #{e.message}"
    end
  end

  private

  def build_report_prompt(data_params)
    """
    Generate a comprehensive business report based on this data:

    #{data_params.to_json}

    Include executive summary, key findings, actionable recommendations,
    and metrics analysis. Make it professional and actionable.
    """
  end
end
```

## Important Considerations

### Schema Validation
- AI responses are automatically validated against schema
- Invalid responses trigger `RubyLLM::SchemaValidationError`
- Always wrap schema operations in error handling blocks

### Performance
- Schema validation adds minimal overhead
- Complex nested schemas may increase processing time
- Consider caching schema definitions for repeated use

### Error Handling
```ruby
begin
  response = chat.ask(prompt)
  # Use response.field_name to access structured data
rescue RubyLLM::SchemaValidationError => e
  # Handle schema validation failure
  Rails.logger.error "Invalid schema response: #{e.message}"
rescue RubyLLM::Error => e
  # Handle general RubyLLM errors
  Rails.logger.error "RubyLLM error: #{e.message}"
end
```

### Best Practices
- Keep schemas simple and focused
- Provide clear field descriptions to guide AI responses
- Use appropriate data types and validation
- Test schemas with various prompts
- Implement fallback strategies for validation failures

### Provider Compatibility
- OpenAI: Full support with JSON mode
- Anthropic: Full support with structured output
- Google: Limited support, may require additional validation
- Local models: Varies by model capability

## Related Documentation

- [Chat Basics](chat-basics.md) - Core chat functionality
- [Multi-Modal Conversations](multi-modal-conversations.md) - File and attachment handling
- [Token Usage](token-usage.md) - Token tracking and cost management
- [RubyLLM Tools](https://rubyllm.com/tools/) - Function calling and tools
- [JSON Schema Guide](https://json-schema.org/) - JSON schema specification