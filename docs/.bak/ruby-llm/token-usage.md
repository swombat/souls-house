# RubyLLM Token Usage and Management

## Version Information
- Documentation version: Latest (v1.7.0+)
- Source: https://rubyllm.com/chat/ and https://rubyllm.com/streaming/
- Fetched: 2025-10-05

## Key Concepts

- **Token Tracking**: Automatic counting of input and output tokens
- **Cost Calculation**: Real-time cost estimation based on provider pricing
- **Token Limits**: Respecting model-specific token limitations
- **Usage Callbacks**: Event handlers for token consumption monitoring
- **Streaming Tokens**: Token counting during real-time streaming responses

## Implementation Guide

### 1. Basic Token Tracking

```ruby
# Simple token tracking
chat = RubyLLM.chat
response = chat.ask("Explain Ruby on Rails in detail")

# Access token information
puts "Input tokens: #{response.input_tokens}"
puts "Output tokens: #{response.output_tokens}"
puts "Total tokens: #{response.total_tokens}"

# Cost estimation (if provider supports it)
puts "Estimated cost: $#{response.cost}" if response.respond_to?(:cost)
```

### 2. Rails Integration with Token Persistence

```ruby
# Migration to add token tracking
class AddTokenTrackingToMessages < ActiveRecord::Migration[7.0]
  def change
    add_column :messages, :input_tokens, :integer, default: 0
    add_column :messages, :output_tokens, :integer, default: 0
    add_column :messages, :total_tokens, :integer, default: 0
    add_column :messages, :estimated_cost, :decimal, precision: 10, scale: 6

    add_index :messages, :total_tokens
    add_index :messages, :estimated_cost
  end
end

# Updated Message model
class Message < ApplicationRecord
  acts_as_message

  # Token tracking methods
  def cost_per_thousand_input_tokens
    case model_name
    when 'gpt-4'
      0.03
    when 'gpt-3.5-turbo'
      0.001
    when 'claude-3-sonnet'
      0.003
    else
      0.001 # Default fallback
    end
  end

  def cost_per_thousand_output_tokens
    case model_name
    when 'gpt-4'
      0.06
    when 'gpt-3.5-turbo'
      0.002
    when 'claude-3-sonnet'
      0.015
    else
      0.002 # Default fallback
    end
  end

  def calculate_cost
    input_cost = (input_tokens / 1000.0) * cost_per_thousand_input_tokens
    output_cost = (output_tokens / 1000.0) * cost_per_thousand_output_tokens
    input_cost + output_cost
  end
end

# Chat with automatic token tracking
chat_record = Chat.create!(user: current_user)
response = chat_record.ask("Generate a detailed product description")

# Tokens are automatically saved to the message
message = chat_record.messages.last
puts "This message cost: $#{message.calculate_cost}"
```

### 3. Token Usage Callbacks and Monitoring

```ruby
# Token usage callback
class TokenTracker
  def self.on_token_usage(input_tokens, output_tokens, model, cost = nil)
    Rails.logger.info "Token usage: #{input_tokens} in, #{output_tokens} out, model: #{model}"

    # Store usage metrics
    TokenUsage.create!(
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens,
      model: model,
      cost: cost,
      timestamp: Time.current
    )

    # Alert if usage is high
    if input_tokens + output_tokens > 10_000
      TokenUsageMailer.high_usage_alert(input_tokens + output_tokens).deliver_later
    end
  end
end

# Configure RubyLLM with token callbacks
RubyLLM.configure do |config|
  config.on_token_usage = TokenTracker.method(:on_token_usage)
end

# Usage tracking model
class TokenUsage < ApplicationRecord
  scope :today, -> { where(timestamp: Date.current.all_day) }
  scope :this_month, -> { where(timestamp: Date.current.all_month) }
  scope :by_model, ->(model) { where(model: model) }

  def self.total_cost_today
    today.sum(:cost) || 0
  end

  def self.total_tokens_today
    today.sum(:total_tokens) || 0
  end

  def self.usage_by_model
    group(:model).sum(:total_tokens)
  end
end
```

### 4. Streaming with Token Tracking

```ruby
# Token tracking during streaming
def stream_with_token_tracking(chat, message)
  total_input_tokens = 0
  total_output_tokens = 0
  chunks = []

  response = chat.ask(message) do |chunk|
    chunks << chunk
    total_output_tokens += chunk.output_tokens if chunk.output_tokens
    total_input_tokens = chunk.input_tokens if chunk.input_tokens

    # Broadcast real-time token updates
    broadcast_replace_to(
      chat,
      target: "token_counter",
      partial: "chats/token_counter",
      locals: {
        input_tokens: total_input_tokens,
        output_tokens: total_output_tokens,
        total_tokens: total_input_tokens + total_output_tokens
      }
    )

    # Yield chunk for processing
    yield chunk if block_given?
  end

  # Final token count
  Rails.logger.info "Streaming complete: #{total_input_tokens} + #{total_output_tokens} = #{total_input_tokens + total_output_tokens} tokens"

  response
end
```

### 5. Token Limits and Management

```ruby
class TokenLimitService
  MODEL_LIMITS = {
    'gpt-4' => 128_000,
    'gpt-3.5-turbo' => 16_385,
    'claude-3-sonnet' => 200_000,
    'claude-3-haiku' => 200_000
  }.freeze

  def initialize(chat, model = 'gpt-4')
    @chat = chat
    @model = model
    @limit = MODEL_LIMITS[@model] || 4_000
  end

  def can_send_message?(message)
    estimated_tokens = estimate_tokens(message)
    conversation_tokens = calculate_conversation_tokens

    (conversation_tokens + estimated_tokens) <= (@limit * 0.9) # 90% safety margin
  end

  def trim_conversation_if_needed(new_message)
    estimated_new_tokens = estimate_tokens(new_message)
    current_tokens = calculate_conversation_tokens

    if (current_tokens + estimated_new_tokens) > (@limit * 0.8)
      trim_conversation_history
    end
  end

  private

  def estimate_tokens(text)
    # Rough estimation: ~4 characters per token for English
    (text.length / 4.0).ceil
  end

  def calculate_conversation_tokens
    @chat.messages.sum(:total_tokens) || 0
  end

  def trim_conversation_history
    # Keep system message and recent messages
    messages_to_keep = [@chat.messages.first] # System message
    recent_messages = @chat.messages.last(10) # Last 10 messages

    messages_to_keep += recent_messages
    messages_to_remove = @chat.messages - messages_to_keep.uniq

    # Archive old messages instead of deleting
    messages_to_remove.each do |message|
      message.update!(archived: true)
    end

    Rails.logger.info "Archived #{messages_to_remove.size} messages to stay within token limit"
  end
end
```

## API Reference

### Token Information Methods

```ruby
# Response token information
response.input_tokens     # Integer: tokens in the request
response.output_tokens    # Integer: tokens in the response
response.total_tokens     # Integer: sum of input and output tokens
response.cost            # Float: estimated cost (if supported)

# Message token information (Rails)
message.input_tokens     # Persisted input token count
message.output_tokens    # Persisted output token count
message.total_tokens     # Persisted total token count
message.estimated_cost   # Calculated cost based on model pricing
```

### Streaming Token Information

```ruby
chat.ask(message) do |chunk|
  chunk.content           # String: incremental content
  chunk.input_tokens      # Integer: total input tokens (constant)
  chunk.output_tokens     # Integer: output tokens so far
  chunk.role             # Symbol: :assistant
end
```

### Token Callback Configuration

```ruby
RubyLLM.configure do |config|
  config.on_token_usage = ->(input, output, model, cost) {
    # Handle token usage
  }

  config.on_token_limit_exceeded = ->(limit, usage) {
    # Handle token limit exceeded
  }
end
```

## Code Examples

### Usage Dashboard Controller

```ruby
class TokenUsageDashboardController < ApplicationController
  before_action :authenticate_admin!

  def index
    @today_usage = TokenUsage.today.sum(:total_tokens)
    @today_cost = TokenUsage.today.sum(:cost)
    @monthly_usage = TokenUsage.this_month.sum(:total_tokens)
    @monthly_cost = TokenUsage.this_month.sum(:cost)

    @usage_by_model = TokenUsage.this_month.group(:model).sum(:total_tokens)
    @cost_by_model = TokenUsage.this_month.group(:model).sum(:cost)

    @top_users = top_users_by_usage
    @usage_trend = daily_usage_trend
  end

  def export
    respond_to do |format|
      format.csv { send_data generate_usage_csv, filename: "token_usage_#{Date.current}.csv" }
    end
  end

  private

  def top_users_by_usage
    User.joins(chats: :messages)
        .where(messages: { created_at: Date.current.all_month })
        .group('users.id', 'users.email')
        .order('SUM(messages.total_tokens) DESC')
        .limit(10)
        .sum('messages.total_tokens')
  end

  def daily_usage_trend
    TokenUsage.where(timestamp: 30.days.ago..Date.current)
              .group_by_day(:timestamp)
              .sum(:total_tokens)
  end

  def generate_usage_csv
    CSV.generate(headers: true) do |csv|
      csv << ['Date', 'Model', 'Input Tokens', 'Output Tokens', 'Total Tokens', 'Cost']

      TokenUsage.this_month.find_each do |usage|
        csv << [
          usage.timestamp.to_date,
          usage.model,
          usage.input_tokens,
          usage.output_tokens,
          usage.total_tokens,
          usage.cost
        ]
      end
    end
  end
end
```

### Budget Management Service

```ruby
class TokenBudgetService
  def initialize(user)
    @user = user
  end

  def check_budget(estimated_tokens)
    current_usage = monthly_usage
    budget_limit = @user.token_budget_limit || 100_000

    if current_usage + estimated_tokens > budget_limit
      raise BudgetExceededError, "Token budget exceeded: #{current_usage + estimated_tokens} > #{budget_limit}"
    end

    remaining_budget = budget_limit - current_usage
    {
      can_proceed: true,
      remaining_tokens: remaining_budget,
      usage_percentage: (current_usage.to_f / budget_limit * 100).round(2)
    }
  end

  def monthly_usage
    @user.chats
         .joins(:messages)
         .where(messages: { created_at: Date.current.all_month })
         .sum('messages.total_tokens')
  end

  def daily_usage
    @user.chats
         .joins(:messages)
         .where(messages: { created_at: Date.current.all_day })
         .sum('messages.total_tokens')
  end

  def cost_this_month
    @user.chats
         .joins(:messages)
         .where(messages: { created_at: Date.current.all_month })
         .sum('messages.estimated_cost')
  end

  def send_budget_warning(percentage)
    if percentage >= 90
      UserMailer.budget_critical(@user, percentage).deliver_now
    elsif percentage >= 80
      UserMailer.budget_warning(@user, percentage).deliver_now
    end
  end
end

class BudgetExceededError < StandardError; end
```

### Real-time Token Counter Component

```erb
<!-- app/views/chats/_token_counter.html.erb -->
<div id="token_counter" class="token-usage-display">
  <div class="token-stats">
    <div class="stat">
      <span class="label">Input:</span>
      <span class="value"><%= input_tokens %></span>
    </div>
    <div class="stat">
      <span class="label">Output:</span>
      <span class="value"><%= output_tokens %></span>
    </div>
    <div class="stat">
      <span class="label">Total:</span>
      <span class="value total"><%= total_tokens %></span>
    </div>
    <% if defined?(estimated_cost) && estimated_cost %>
      <div class="stat">
        <span class="label">Cost:</span>
        <span class="value cost">$<%= '%.4f' % estimated_cost %></span>
      </div>
    <% end %>
  </div>

  <div class="token-progress">
    <% model_limit = 128_000 %> <!-- Adjust based on model -->
    <% usage_percentage = (total_tokens.to_f / model_limit * 100).round(1) %>
    <div class="progress-bar">
      <div class="progress-fill" style="width: <%= [usage_percentage, 100].min %>%"
           class="<%= 'warning' if usage_percentage > 80 %>">
      </div>
    </div>
    <small><%= usage_percentage %>% of token limit used</small>
  </div>
</div>
```

### Background Token Monitoring Job

```ruby
class TokenMonitoringJob < ApplicationJob
  queue_as :monitoring

  def perform
    check_daily_limits
    check_monthly_budgets
    generate_usage_reports
    cleanup_old_token_data
  end

  private

  def check_daily_limits
    User.joins(chats: :messages)
        .where(messages: { created_at: Date.current.all_day })
        .group('users.id')
        .having('SUM(messages.total_tokens) > ?', 50_000) # Daily limit
        .find_each do |user|
          UserMailer.daily_limit_exceeded(user).deliver_now
        end
  end

  def check_monthly_budgets
    User.where.not(token_budget_limit: nil).find_each do |user|
      budget_service = TokenBudgetService.new(user)
      usage = budget_service.monthly_usage
      limit = user.token_budget_limit

      percentage = (usage.to_f / limit * 100).round(2)

      if percentage >= 90 && !user.budget_warning_sent_at&.today?
        budget_service.send_budget_warning(percentage)
        user.update!(budget_warning_sent_at: Time.current)
      end
    end
  end

  def generate_usage_reports
    if Date.current.day == 1 # First day of month
      AdminMailer.monthly_token_usage_report(
        previous_month_usage_data
      ).deliver_now
    end
  end

  def cleanup_old_token_data
    # Keep detailed data for 3 months, summarized data for 1 year
    TokenUsage.where('timestamp < ?', 3.months.ago).delete_all
  end

  def previous_month_usage_data
    last_month = 1.month.ago
    {
      total_tokens: TokenUsage.where(timestamp: last_month.all_month).sum(:total_tokens),
      total_cost: TokenUsage.where(timestamp: last_month.all_month).sum(:cost),
      top_models: TokenUsage.where(timestamp: last_month.all_month)
                           .group(:model)
                           .sum(:total_tokens)
                           .sort_by(&:last)
                           .reverse
                           .first(5)
    }
  end
end
```

### Stimulus Controller for Live Token Updates

```javascript
// app/javascript/controllers/token_counter_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "output", "total", "cost", "progress"]
  static values = { limit: Number }

  connect() {
    this.updateProgress()
  }

  inputTargetConnected() {
    this.updateProgress()
  }

  outputTargetConnected() {
    this.updateProgress()
  }

  updateProgress() {
    if (this.hasProgressTarget && this.hasTotalTarget) {
      const total = parseInt(this.totalTarget.textContent) || 0
      const percentage = Math.min((total / this.limitValue) * 100, 100)

      this.progressTarget.style.width = `${percentage}%`

      // Update color based on usage
      this.progressTarget.className = this.getProgressClass(percentage)
    }
  }

  getProgressClass(percentage) {
    if (percentage >= 90) return "progress-fill critical"
    if (percentage >= 80) return "progress-fill warning"
    if (percentage >= 60) return "progress-fill caution"
    return "progress-fill normal"
  }

  // Called when token count updates during streaming
  updateTokens(event) {
    const { input, output, total, cost } = event.detail

    if (this.hasInputTarget) this.inputTarget.textContent = input
    if (this.hasOutputTarget) this.outputTarget.textContent = output
    if (this.hasTotalTarget) this.totalTarget.textContent = total
    if (this.hasCostTarget && cost) this.costTarget.textContent = `$${cost.toFixed(4)}`

    this.updateProgress()
  }
}
```

## Important Considerations

### Cost Management
- Monitor token usage closely to control costs
- Implement budget limits and alerts
- Consider using cheaper models for simple tasks
- Cache responses when appropriate to avoid repeat API calls

### Performance Impact
- Token counting adds minimal overhead
- Store token counts in database for historical analysis
- Use background jobs for token-intensive operations
- Implement proper indexing on token-related database columns

### Accuracy
- Token counts may vary slightly between providers
- Streaming token counts may be estimates until completion
- Different models have different tokenization methods
- Factor in conversation context when estimating usage

### Security and Privacy
- Token usage data may be sensitive for billing
- Implement proper access controls for usage dashboards
- Consider data retention policies for token usage logs
- Audit high-usage patterns for potential abuse

### Model-Specific Considerations
```ruby
# Different models have different token costs and limits
MODEL_PRICING = {
  'gpt-4' => { input: 0.03, output: 0.06, limit: 128_000 },
  'gpt-3.5-turbo' => { input: 0.001, output: 0.002, limit: 16_385 },
  'claude-3-sonnet' => { input: 0.003, output: 0.015, limit: 200_000 },
  'claude-3-haiku' => { input: 0.00025, output: 0.00125, limit: 200_000 }
}.freeze
```

## Related Documentation

- [Chat Basics](chat-basics.md) - Core chat functionality
- [Multi-Modal Conversations](multi-modal-conversations.md) - File and attachment handling
- [Structured Output](structured-output.md) - JSON responses and schemas
- [RubyLLM Streaming](https://rubyllm.com/streaming/) - Real-time responses
- [RubyLLM Configuration](https://rubyllm.com/configuration/) - Setup and configuration