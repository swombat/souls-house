# RubyLLM Content Moderation Documentation

RubyLLM provides AI-powered content moderation to identify and filter potentially harmful content before processing with language models, ensuring safer AI interactions.

## Version Information
- Available in: RubyLLM v1.8.0+
- Documentation source: https://rubyllm.com/moderation/
- Fetched: 2025-10-05

## Key Concepts

- **Content Moderation**: AI-powered detection of potentially harmful content
- **Category-based Detection**: Identifies specific types of harmful content
- **Risk Scoring**: Numerical scores (0.0-1.0) indicating likelihood of harmful content
- **Pre-processing Filter**: Validates content before sending to LLMs
- **Custom Thresholds**: Configurable sensitivity levels for different use cases

## Moderation Categories

RubyLLM checks for multiple categories of potentially harmful content:

- **Sexual content**: Sexually explicit or suggestive material
- **Hate speech**: Content promoting hatred against groups or individuals
- **Harassment**: Bullying, threatening, or abusive content
- **Self-harm**: Content promoting or describing self-harm or suicide
- **Violence**: Content describing or promoting violence
- **Content involving minors**: Inappropriate content related to children

## Basic Usage

### Simple Content Moderation

```ruby
# Basic moderation check
result = RubyLLM.moderate("User input text that needs checking")

if result.flagged?
  puts "Content flagged as potentially harmful"
  puts "Categories: #{result.flagged_categories}"
else
  puts "Content appears safe to process"
  # Proceed with LLM processing
end
```

### Accessing Moderation Details

```ruby
result = RubyLLM.moderate("Some user content")

# Check overall flag status
puts "Flagged: #{result.flagged?}"

# Access category-specific scores (0.0 to 1.0)
puts "Sexual content score: #{result.sexual_score}"
puts "Hate speech score: #{result.hate_score}"
puts "Harassment score: #{result.harassment_score}"
puts "Self-harm score: #{result.self_harm_score}"
puts "Violence score: #{result.violence_score}"
puts "Minors score: #{result.minors_score}"

# Get flagged categories (array of symbols)
puts "Flagged categories: #{result.flagged_categories}"
```

## Rails Integration

### Controller-Level Moderation

```ruby
class ChatsController < ApplicationController
  before_action :moderate_content, only: [:create]

  def create
    @chat = current_user.chats.build
    @message = @chat.messages.build(message_params)

    if @message.save
      # Content has already been moderated, safe to process
      ProcessChatMessageJob.perform_later(@message.id)
      render json: { status: "processing" }
    else
      render json: { errors: @message.errors }, status: :unprocessable_entity
    end
  end

  private

  def message_params
    params.require(:message).permit(:content, :role)
  end

  def moderate_content
    content = params.dig(:message, :content)
    return if content.blank?

    moderation_result = RubyLLM.moderate(content)

    if moderation_result.flagged?
      render json: {
        error: "Content violates community guidelines",
        flagged_categories: moderation_result.flagged_categories,
        message: "Please revise your message and try again"
      }, status: :forbidden
    end
  end
end
```

### Model-Level Validation

```ruby
class Message < ApplicationRecord
  belongs_to :chat
  belongs_to :user

  validates :content, presence: true
  validate :content_moderation, if: :content_changed?

  private

  def content_moderation
    return if content.blank?

    moderation_result = RubyLLM.moderate(content)

    if moderation_result.flagged?
      flagged_categories = moderation_result.flagged_categories.map(&:to_s).join(", ")
      errors.add(:content, "violates community guidelines (#{flagged_categories})")
    end
  rescue => e
    Rails.logger.error "Moderation check failed: #{e.message}"
    # Optionally fail open or closed depending on your security requirements
    errors.add(:content, "could not be verified for safety")
  end
end
```

### Background Job Integration

```ruby
class ProcessUserContentJob < ApplicationJob
  queue_as :content_processing

  def perform(content_id)
    content = UserContent.find(content_id)

    # Moderate before processing
    moderation_result = RubyLLM.moderate(content.text)

    if moderation_result.flagged?
      handle_flagged_content(content, moderation_result)
    else
      process_safe_content(content)
    end
  end

  private

  def handle_flagged_content(content, moderation_result)
    content.update!(
      status: :flagged,
      moderation_flags: moderation_result.flagged_categories,
      moderation_scores: extract_scores(moderation_result)
    )

    # Notify administrators
    AdminNotificationMailer.flagged_content(content.id).deliver_now

    # Notify user
    UserMailer.content_moderation_notice(content.user, content).deliver_now
  end

  def process_safe_content(content)
    content.update!(status: :approved)

    # Continue with LLM processing
    chat = RubyLLM.chat
    response = chat.ask(content.text)

    content.update!(
      ai_response: response,
      status: :processed
    )
  end

  def extract_scores(moderation_result)
    {
      sexual: moderation_result.sexual_score,
      hate: moderation_result.hate_score,
      harassment: moderation_result.harassment_score,
      self_harm: moderation_result.self_harm_score,
      violence: moderation_result.violence_score,
      minors: moderation_result.minors_score
    }
  end
end
```

## Custom Moderation Policies

### Configurable Thresholds

```ruby
class ModerationPolicy
  DEFAULT_THRESHOLDS = {
    sexual: 0.7,
    hate: 0.5,
    harassment: 0.6,
    self_harm: 0.3, # Lower threshold for safety
    violence: 0.5,
    minors: 0.2     # Very low threshold for protection
  }.freeze

  def self.check_content(content, thresholds: DEFAULT_THRESHOLDS)
    moderation_result = RubyLLM.moderate(content)

    custom_flags = []

    thresholds.each do |category, threshold|
      score_method = "#{category}_score"
      if moderation_result.respond_to?(score_method)
        score = moderation_result.public_send(score_method)
        custom_flags << category if score > threshold
      end
    end

    {
      flagged: custom_flags.any?,
      flagged_categories: custom_flags,
      original_result: moderation_result,
      custom_thresholds: thresholds
    }
  end
end

# Usage with custom thresholds
strict_policy = {
  sexual: 0.3,
  hate: 0.2,
  harassment: 0.3,
  self_harm: 0.1,
  violence: 0.2,
  minors: 0.1
}

result = ModerationPolicy.check_content(user_input, thresholds: strict_policy)
```

### Context-Aware Moderation

```ruby
class ContextualModerationService
  def self.moderate_for_context(content, context_type)
    base_result = RubyLLM.moderate(content)

    case context_type
    when :public_forum
      # Stricter moderation for public content
      apply_strict_policy(base_result)
    when :private_chat
      # More lenient for private conversations
      apply_lenient_policy(base_result)
    when :educational
      # Context-aware for educational content
      apply_educational_policy(base_result)
    when :creative_writing
      # Specialized handling for creative content
      apply_creative_policy(base_result)
    else
      base_result
    end
  end

  private

  def self.apply_strict_policy(result)
    # Flag content with lower thresholds in public contexts
    additional_flags = []
    additional_flags << :hate if result.hate_score > 0.3
    additional_flags << :harassment if result.harassment_score > 0.4

    OpenStruct.new(
      flagged?: result.flagged? || additional_flags.any?,
      flagged_categories: result.flagged_categories + additional_flags,
      context: :public_forum,
      original_result: result
    )
  end

  def self.apply_educational_policy(result)
    # More nuanced handling for educational content
    educational_flags = result.flagged_categories.reject do |category|
      # Allow some violence/historical content in educational context
      category == :violence && result.violence_score < 0.8
    end

    OpenStruct.new(
      flagged?: educational_flags.any?,
      flagged_categories: educational_flags,
      context: :educational,
      original_result: result
    )
  end
end
```

## Advanced Moderation Features

### Batch Moderation

```ruby
class BatchModerationService
  MAX_BATCH_SIZE = 50

  def self.moderate_batch(contents)
    contents.in_groups_of(MAX_BATCH_SIZE, false) do |batch|
      results = batch.map do |content|
        {
          content: content,
          moderation: RubyLLM.moderate(content),
          timestamp: Time.current
        }
      end

      process_batch_results(results)
    end
  end

  private

  def self.process_batch_results(results)
    flagged_count = results.count { |r| r[:moderation].flagged? }

    Rails.logger.info "Batch moderation complete: #{flagged_count}/#{results.size} flagged"

    results.each do |result|
      if result[:moderation].flagged?
        ModerationEvent.create!(
          content: result[:content],
          flagged_categories: result[:moderation].flagged_categories,
          scores: extract_all_scores(result[:moderation]),
          processed_at: result[:timestamp]
        )
      end
    end

    results
  end

  def self.extract_all_scores(moderation_result)
    {
      sexual: moderation_result.sexual_score,
      hate: moderation_result.hate_score,
      harassment: moderation_result.harassment_score,
      self_harm: moderation_result.self_harm_score,
      violence: moderation_result.violence_score,
      minors: moderation_result.minors_score
    }
  end
end
```

### Moderation Logging and Analytics

```ruby
class ModerationAnalytics
  def self.log_moderation_event(content, result, user: nil, context: nil)
    ModerationLog.create!(
      content_hash: Digest::SHA256.hexdigest(content),
      content_length: content.length,
      user: user,
      context: context,
      flagged: result.flagged?,
      flagged_categories: result.flagged_categories,
      scores: {
        sexual: result.sexual_score,
        hate: result.hate_score,
        harassment: result.harassment_score,
        self_harm: result.self_harm_score,
        violence: result.violence_score,
        minors: result.minors_score
      },
      processed_at: Time.current
    )
  end

  def self.moderation_stats(date_range = 1.week.ago..Time.current)
    logs = ModerationLog.where(processed_at: date_range)

    {
      total_checks: logs.count,
      flagged_count: logs.where(flagged: true).count,
      flagged_percentage: (logs.where(flagged: true).count.to_f / logs.count * 100).round(2),
      category_breakdown: category_breakdown(logs),
      top_flagged_categories: top_flagged_categories(logs)
    }
  end

  private

  def self.category_breakdown(logs)
    flagged_logs = logs.where(flagged: true)
    categories = [:sexual, :hate, :harassment, :self_harm, :violence, :minors]

    categories.map do |category|
      count = flagged_logs.where("flagged_categories @> ?", [category].to_json).count
      [category, count]
    end.to_h
  end

  def self.top_flagged_categories(logs)
    category_breakdown(logs).sort_by { |_, count| -count }.first(3)
  end
end
```

## Error Handling and Fallbacks

### Robust Moderation with Fallbacks

```ruby
class SafeModerationService
  def self.moderate_with_fallback(content, fallback_strategy: :fail_closed)
    begin
      result = RubyLLM.moderate(content)
      log_successful_moderation(content, result)
      result
    rescue RubyLLM::AuthenticationError => e
      handle_auth_error(e, content, fallback_strategy)
    rescue RubyLLM::RateLimitError => e
      handle_rate_limit_error(e, content, fallback_strategy)
    rescue RubyLLM::BadRequestError => e
      handle_bad_request_error(e, content, fallback_strategy)
    rescue StandardError => e
      handle_generic_error(e, content, fallback_strategy)
    end
  end

  private

  def self.handle_auth_error(error, content, fallback_strategy)
    Rails.logger.error "Moderation authentication failed: #{error.message}"

    case fallback_strategy
    when :fail_closed
      create_fallback_result(flagged: true, reason: "Authentication failed")
    when :fail_open
      create_fallback_result(flagged: false, reason: "Authentication failed - allowing content")
    when :manual_review
      queue_for_manual_review(content, error)
      create_fallback_result(flagged: true, reason: "Queued for manual review")
    end
  end

  def self.handle_rate_limit_error(error, content, fallback_strategy)
    Rails.logger.warn "Moderation rate limited: #{error.message}"

    case fallback_strategy
    when :fail_closed
      create_fallback_result(flagged: true, reason: "Rate limited")
    when :retry_later
      RetryModerationJob.set(wait: 30.seconds).perform_later(content)
      create_fallback_result(flagged: true, reason: "Retry scheduled")
    else
      create_fallback_result(flagged: false, reason: "Rate limited - allowing content")
    end
  end

  def self.create_fallback_result(flagged:, reason:)
    OpenStruct.new(
      flagged?: flagged,
      flagged_categories: flagged ? [:system_error] : [],
      fallback_reason: reason,
      sexual_score: 0.0,
      hate_score: 0.0,
      harassment_score: 0.0,
      self_harm_score: 0.0,
      violence_score: 0.0,
      minors_score: 0.0
    )
  end

  def self.queue_for_manual_review(content, error)
    ManualReviewQueue.create!(
      content_hash: Digest::SHA256.hexdigest(content),
      content_preview: content[0..200],
      error_message: error.message,
      priority: :high,
      queued_at: Time.current
    )
  end
end
```

## Integration with User Management

### User Moderation History

```ruby
class User < ApplicationRecord
  has_many :moderation_events, dependent: :destroy

  def moderation_score
    recent_events = moderation_events.where(created_at: 30.days.ago..Time.current)
    return 0.0 if recent_events.empty?

    flagged_count = recent_events.where(flagged: true).count
    (flagged_count.to_f / recent_events.count).round(2)
  end

  def moderate_user_content(content, context: nil)
    result = RubyLLM.moderate(content)

    # Log the moderation event
    moderation_events.create!(
      content_hash: Digest::SHA256.hexdigest(content),
      flagged: result.flagged?,
      flagged_categories: result.flagged_categories,
      context: context,
      scores: {
        sexual: result.sexual_score,
        hate: result.hate_score,
        harassment: result.harassment_score,
        self_harm: result.self_harm_score,
        violence: result.violence_score,
        minors: result.minors_score
      }
    )

    # Check if user needs attention
    check_user_moderation_pattern if result.flagged?

    result
  end

  private

  def check_user_moderation_pattern
    recent_flags = moderation_events.where(
      flagged: true,
      created_at: 24.hours.ago..Time.current
    ).count

    if recent_flags >= 3
      # Flag for admin review
      AdminReviewQueue.create!(
        user: self,
        reason: "Multiple content violations in 24 hours",
        violation_count: recent_flags
      )
    end
  end
end
```

### Automatic User Actions

```ruby
class AutoModerationService
  VIOLATION_THRESHOLDS = {
    warning: 3,
    temporary_restriction: 5,
    permanent_ban: 10
  }.freeze

  def self.process_user_violation(user, moderation_result)
    return unless moderation_result.flagged?

    violation_count = user.moderation_events.where(
      flagged: true,
      created_at: 30.days.ago..Time.current
    ).count

    case violation_count
    when VIOLATION_THRESHOLDS[:warning]
      issue_warning(user)
    when VIOLATION_THRESHOLDS[:temporary_restriction]
      apply_temporary_restriction(user)
    when VIOLATION_THRESHOLDS[:permanent_ban]
      apply_permanent_ban(user)
    end
  end

  private

  def self.issue_warning(user)
    UserMailer.moderation_warning(user).deliver_now

    user.update!(
      warning_issued_at: Time.current,
      warning_count: user.warning_count + 1
    )
  end

  def self.apply_temporary_restriction(user)
    user.update!(
      restricted_until: 7.days.from_now,
      restriction_reason: "Repeated content violations"
    )

    UserMailer.account_restricted(user).deliver_now
  end

  def self.apply_permanent_ban(user)
    user.update!(
      banned_at: Time.current,
      ban_reason: "Multiple severe content violations"
    )

    UserMailer.account_banned(user).deliver_now
  end
end
```

## Testing Moderation

### RSpec Testing Examples

```ruby
RSpec.describe "Content Moderation" do
  describe "RubyLLM.moderate" do
    it "flags inappropriate content" do
      # Mock the moderation response
      mock_result = double("ModerationResult",
        flagged?: true,
        flagged_categories: [:hate, :harassment],
        hate_score: 0.8,
        harassment_score: 0.7,
        sexual_score: 0.1,
        self_harm_score: 0.0,
        violence_score: 0.2,
        minors_score: 0.0
      )

      allow(RubyLLM).to receive(:moderate).and_return(mock_result)

      result = RubyLLM.moderate("inappropriate content")

      expect(result.flagged?).to be true
      expect(result.flagged_categories).to include(:hate, :harassment)
    end

    it "allows safe content" do
      mock_result = double("ModerationResult",
        flagged?: false,
        flagged_categories: [],
        hate_score: 0.1,
        harassment_score: 0.0,
        sexual_score: 0.0,
        self_harm_score: 0.0,
        violence_score: 0.0,
        minors_score: 0.0
      )

      allow(RubyLLM).to receive(:moderate).and_return(mock_result)

      result = RubyLLM.moderate("Hello, how are you today?")

      expect(result.flagged?).to be false
      expect(result.flagged_categories).to be_empty
    end
  end

  describe "Message validation" do
    let(:user) { create(:user) }
    let(:chat) { create(:chat, user: user) }

    it "prevents saving flagged messages" do
      # Mock flagged content
      allow(RubyLLM).to receive(:moderate).and_return(
        double(flagged?: true, flagged_categories: [:hate])
      )

      message = chat.messages.build(content: "flagged content", user: user)

      expect(message).not_to be_valid
      expect(message.errors[:content]).to include(/violates community guidelines/)
    end

    it "allows safe messages" do
      # Mock safe content
      allow(RubyLLM).to receive(:moderate).and_return(
        double(flagged?: false, flagged_categories: [])
      )

      message = chat.messages.build(content: "Hello there!", user: user)

      expect(message).to be_valid
    end
  end
end

# Integration test
RSpec.describe "Chat moderation", type: :request do
  let(:user) { create(:user) }
  let(:chat) { create(:chat, user: user) }

  before { sign_in user }

  it "blocks inappropriate messages" do
    # Mock moderation to flag content
    allow(RubyLLM).to receive(:moderate).and_return(
      double(flagged?: true, flagged_categories: [:harassment])
    )

    post chat_messages_path(chat), params: {
      message: { content: "inappropriate content" }
    }

    expect(response).to have_http_status(:forbidden)

    json_response = JSON.parse(response.body)
    expect(json_response["error"]).to include("community guidelines")
    expect(json_response["flagged_categories"]).to include("harassment")
  end
end
```

## Configuration and Best Practices

### Global Configuration

```ruby
# config/initializers/ruby_llm.rb
RubyLLM.configure do |config|
  config.openai_api_key = Rails.application.credentials.openai_api_key

  # Moderation settings
  config.moderation_model = "text-moderation-latest"
  config.moderation_timeout = 10.seconds

  # Logging
  config.log_moderation_events = Rails.env.production?
end
```

### Environment-Specific Settings

```ruby
# Different strictness levels per environment
class ModerationConfig
  def self.thresholds_for_environment
    case Rails.env
    when "production"
      {
        sexual: 0.6,
        hate: 0.4,
        harassment: 0.5,
        self_harm: 0.2,
        violence: 0.4,
        minors: 0.1
      }
    when "staging"
      {
        sexual: 0.5,
        hate: 0.3,
        harassment: 0.4,
        self_harm: 0.2,
        violence: 0.3,
        minors: 0.1
      }
    when "development"
      {
        sexual: 0.8,
        hate: 0.7,
        harassment: 0.7,
        self_harm: 0.5,
        violence: 0.7,
        minors: 0.3
      }
    end
  end
end
```

## Important Considerations

### Security Guidelines
- **Always moderate user-generated content** before sending to LLMs
- Store moderation logs for compliance and audit purposes
- Implement graceful fallbacks when moderation services are unavailable
- Never expose raw moderation scores to end users

### Performance Considerations
- Use background jobs for non-blocking moderation
- Implement caching for frequently moderated content patterns
- Monitor API rate limits and costs
- Consider batching for high-volume applications

### Legal and Compliance
- Understand your jurisdiction's content moderation requirements
- Maintain audit logs for legal compliance
- Implement user appeal processes for false positives
- Regular review and update of moderation policies

### User Experience
- Provide clear, actionable feedback when content is flagged
- Implement progressive enforcement (warnings before bans)
- Allow users to edit and resubmit flagged content
- Ensure moderation decisions are consistent and fair

## Related Documentation
- [RubyLLM Configuration Guide](https://rubyllm.com/configuration/)
- [OpenAI Moderation API](https://platform.openai.com/docs/guides/moderation)
- [Rails Security Guide](https://guides.rubyonrails.org/security.html)