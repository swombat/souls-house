# RubyLLM Moderation API Documentation

## Version Information
- Feature: RubyLLM Moderation API
- Available since: v1.8.0
- Documentation source: https://rubyllm.com/moderation/
- Fetched: 2026-01-21

## Overview

The RubyLLM moderation API provides content moderation capabilities using OpenAI's moderation endpoints. It analyzes text for potentially harmful content across 11 categories and returns confidence scores and flags for each category.

## Key Concepts

- **Moderation Check**: Analyzes input text and returns flagged status and category breakdowns
- **Categories**: 11 predefined content categories (sexual, hate, harassment, violence, self-harm, and variants)
- **Scores**: Confidence scores from 0.0 to 1.0 indicating likelihood of policy violation
- **Flagged Status**: Boolean indicating if content violated any policies
- **Models**: Default is `omni-moderation-latest`, alternative is `text-moderation-007`

## Configuration

Setup requires an OpenAI API key:

```ruby
# config/initializers/ruby_llm.rb
RubyLLM.configure do |config|
  config.openai_api_key = ENV['OPENAI_API_KEY']
  config.default_moderation_model = "omni-moderation-latest"  # Optional
end
```

## Basic Usage

### Simple Moderation Check

```ruby
result = RubyLLM.moderate("Your text here")
puts result.flagged?  # Returns boolean
```

### Alternative Calling Methods

```ruby
# Via Moderation namespace
result = RubyLLM::Moderation.moderate("Your content here")

# With explicit model
result = RubyLLM.moderate(
  "User message",
  model: "text-moderation-007",
  provider: "openai"
)

# With assume_model_exists option
result = RubyLLM.moderate(
  "Content to check",
  provider: "openai",
  assume_model_exists: true
)
```

## Response Structure

The moderation result object provides the following properties:

### Core Properties

- **`flagged?`** - Boolean indicating if content violated any policies
- **`flagged_categories`** - Array of category names that were flagged
- **`id`** - Unique identifier for the moderation request
- **`model`** - Model used for analysis (e.g., "omni-moderation-latest")

### Detailed Data

- **`categories`** - Hash with boolean flags for each category
- **`category_scores`** - Hash with confidence scores (0.0-1.0) for each category
- **`results`** - Full raw response array from the API

### Example Response Inspection

```ruby
result = RubyLLM.moderate("Some user input text")

# Check if flagged
if result.flagged?
  puts "Flagged for: #{result.flagged_categories.join(', ')}"
end

# Access category scores
scores = result.category_scores
puts "Sexual content score: #{scores['sexual']}"
puts "Harassment score: #{scores['harassment']}"
puts "Violence score: #{scores['violence']}"

# Access category flags
categories = result.categories
puts "Contains hate speech: #{categories['hate']}"
puts "Contains self-harm: #{categories['self-harm']}"
```

## Moderation Categories

The API checks 11 content categories:

1. **`sexual`** - Sexually explicit or suggestive content
2. **`sexual/minors`** - Sexual content involving minors
3. **`hate`** - Content promoting hate based on identity
4. **`hate/threatening`** - Hateful content that includes threats
5. **`harassment`** - Content intended to harass, threaten, or bully
6. **`harassment/threatening`** - Harassing content that includes threats
7. **`self-harm`** - Content promoting self-harm or suicide
8. **`self-harm/intent`** - Content expressing intent to self-harm
9. **`self-harm/instructions`** - Instructions for self-harm
10. **`violence`** - Content promoting or glorifying violence
11. **`violence/graphic`** - Graphic violent content

## Implementation Patterns

### Pre-Chat Safety Layer

Moderate user input before processing through chat systems:

```ruby
def safe_chat_response(user_input)
  moderation = RubyLLM.moderate(user_input)

  if moderation.flagged?
    flagged_categories = moderation.flagged_categories.join(', ')
    return { error: "Content flagged for: #{flagged_categories}", safe: false }
  end

  response = RubyLLM.chat.ask(user_input)
  { content: response.content, safe: true }
end
```

### Custom Risk Thresholds

Implement multi-tier responses based on category scores:

```ruby
def assess_content_risk(text)
  result = RubyLLM.moderate(text)
  scores = result.category_scores

  high_risk = scores.any? { |_, score| score > 0.8 }
  medium_risk = scores.any? { |_, score| score > 0.5 }

  case
  when high_risk
    { risk: :high, action: :block, message: "Content blocked" }
  when medium_risk
    { risk: :medium, action: :review, message: "Content flagged for review" }
  else
    { risk: :low, action: :allow, message: "Content approved" }
  end
end
```

### User-Friendly Error Messages

Provide category-specific feedback:

```ruby
def user_friendly_moderation(content)
  result = RubyLLM.moderate(content)
  return { approved: true } unless result.flagged?

  categories = result.flagged_categories
  message = case
  when categories.include?('harassment')
    "Please keep interactions respectful and constructive."
  when categories.include?('sexual')
    "This content appears inappropriate for our platform."
  when categories.include?('violence')
    "Please avoid content promoting violence or harm."
  else
    "This content doesn't meet our community guidelines."
  end

  { approved: false, message: message, categories: categories }
end
```

### Rails Controller Integration

```ruby
class MessagesController < ApplicationController
  def create
    content = params[:message]
    moderation_result = RubyLLM.moderate(content)

    if moderation_result.flagged?
      render json: {
        error: "Message not allowed",
        categories: moderation_result.flagged_categories
      }, status: :unprocessable_entity
    else
      message = Message.create!(content: content, user: current_user)
      render json: message, status: :created
    end
  end
end
```

### Background Job Processing

Process moderation checks asynchronously:

```ruby
class ModerationJob < ApplicationJob
  queue_as :default

  def perform(message_ids)
    messages = Message.where(id: message_ids)
    messages.each do |message|
      result = RubyLLM.moderate(message.content)
      message.update!(
        moderation_flagged: result.flagged?,
        moderation_categories: result.flagged_categories,
        moderation_scores: result.category_scores
      )
    end
  end
end
```

## Error Handling

The API throws specific exceptions that should be handled:

```ruby
begin
  result = RubyLLM.moderate("User content")
  handle_unsafe_content(result) if result.flagged?
rescue RubyLLM::ConfigurationError => e
  # Missing API key or configuration
  logger.error "Moderation not configured: #{e.message}"
rescue RubyLLM::RateLimitError => e
  # Rate limit exceeded
  logger.warn "Moderation rate limited: #{e.message}"
rescue RubyLLM::Error => e
  # General API error
  logger.error "Moderation failed: #{e.message}"
end
```

### Exception Types

- **`RubyLLM::ConfigurationError`** - Missing credentials or invalid configuration
- **`RubyLLM::RateLimitError`** - API rate limit exceeded
- **`RubyLLM::Error`** - General API failures

## Performance Considerations

- **Cost**: Moderation calls are less expensive than chat completions
- **Rate Limits**: Generous rate limits support screening all user inputs
- **Speed**: Fast enough for real-time pre-submission moderation
- **Async Processing**: Consider background jobs for non-blocking moderation of existing content

## Important Considerations

### When to Use Moderation

- **Pre-submission**: Check user input before saving or processing
- **Pre-LLM**: Screen content before sending to language models
- **Batch processing**: Review existing content for policy violations
- **Real-time**: Provide immediate feedback to users

### Score Interpretation

- **0.0-0.4**: Low risk, typically safe content
- **0.5-0.7**: Medium risk, may warrant review
- **0.8-1.0**: High risk, likely policy violation

### Category-Specific Handling

Different categories may warrant different responses:
- Block immediately: `sexual/minors`, `self-harm/instructions`
- Warn and allow review: `harassment`, `hate`
- Context-dependent: `sexual`, `violence` (may be acceptable in certain contexts)

## Related Documentation

- [RubyLLM Official Documentation](https://rubyllm.com/)
- [OpenAI Moderation API](https://platform.openai.com/docs/guides/moderation)
- [RubyLLM GitHub Repository](https://github.com/alexrudall/ruby-llm)

## Migration Notes

For applications upgrading to RubyLLM v1.8.0+:
- Ensure OpenAI API key is configured
- Test moderation on representative sample of your content
- Establish appropriate thresholds for your use case
- Plan for handling false positives/negatives
- Consider user appeal/review processes for flagged content
