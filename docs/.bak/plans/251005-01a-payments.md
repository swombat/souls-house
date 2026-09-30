# Payments System Implementation Plan

## Executive Summary

Implement a flexible, Rails-idiomatic payments system that supports multiple charging models for AI token usage. The system integrates the Pay gem with RubyLLM's token tracking to provide subscription-based, pay-as-you-go, and hybrid billing models. All billing is account-based (not user-based), supporting both personal and team accounts.

## Architecture Overview

### Core Philosophy

This implementation follows Rails conventions strictly:
- **Fat models, skinny controllers** - All business logic lives in models
- **Concerns for shared behavior** - Token gating extracted as a concern
- **Association-based scoping** - Use Rails associations for data access
- **No over-engineering** - No service objects, just clean Rails patterns
- **Database-stored configuration** - Plans in database, not config files

### Technology Stack

- **Payment Processing**: Pay gem (Stripe integration)
- **Token Tracking**: RubyLLM's built-in token tracking
- **Model Pricing**: RubyLLM Model Registry
- **Background Processing**: Solid Queue (Rails 8)
- **Database**: PostgreSQL with Rails validations

### Key Concepts

1. **Plans** - Define subscription tiers with token allowances
2. **Credits** - Pay-as-you-go token purchases
3. **Token Balances** - Track available tokens per account
4. **Token Usage** - Record consumption by model and cost
5. **Auto-recharge** - Automatic credit purchases when balance low

## Database Schema

### New Tables

#### plans
```ruby
create_table :plans do |t|
  t.string :name, null: false
  t.string :stripe_price_id
  t.integer :status, null: false, default: 0  # active, legacy, inactive
  t.decimal :monthly_price_cents, precision: 10, scale: 2
  t.integer :monthly_tokens, null: false, default: 0
  t.text :description
  t.jsonb :metadata, default: {}
  t.timestamps

  t.index :status
  t.index :stripe_price_id, unique: true
end

# Enum: { active: 0, legacy: 1, inactive: 2 }
```

#### account_subscriptions (via Pay gem)
```ruby
# Pay gem provides pay_subscriptions table
# Links accounts to plans via subscription
```

#### credits
```ruby
create_table :credits do |t|
  t.references :account, null: false, foreign_key: true
  t.integer :amount_tokens, null: false
  t.integer :cost_cents, null: false
  t.string :purchase_type, null: false  # subscription_included, purchased, bonus
  t.datetime :expires_at
  t.timestamps

  t.index [:account_id, :created_at]
  t.index :expires_at
end
```

#### token_usages
```ruby
create_table :token_usages do |t|
  t.references :account, null: false, foreign_key: true
  t.references :chat, null: false, foreign_key: true
  t.references :message, null: false, foreign_key: true
  t.string :model_id, null: false
  t.integer :input_tokens, null: false, default: 0
  t.integer :output_tokens, null: false, default: 0
  t.integer :total_tokens, null: false, default: 0
  t.decimal :cost_cents, precision: 10, scale: 2
  t.datetime :created_at, null: false

  t.index [:account_id, :created_at]
  t.index [:chat_id, :created_at]
  t.index :model_id
end
```

### Schema Modifications

#### accounts
```ruby
add_column :accounts, :token_balance, :integer, default: 0, null: false
add_column :accounts, :auto_recharge_enabled, :boolean, default: false
add_column :accounts, :auto_recharge_amount_cents, :integer
add_column :accounts, :auto_recharge_threshold_tokens, :integer
add_column :accounts, :auto_recharge_limit_cents, :integer

add_index :accounts, :token_balance
```

#### messages (already has token columns)
```ruby
# Already exists:
# t.integer :input_tokens
# t.integer :output_tokens
# Add:
add_column :messages, :cost_cents, :decimal, precision: 10, scale: 2
```

## Model Implementation

### Plan Model

```ruby
class Plan < ApplicationRecord
  # Pay gem integration
  include Pay::Billable

  # Enums
  enum :status, { active: 0, legacy: 1, inactive: 2 }

  # Associations
  has_many :subscriptions, class_name: "Pay::Subscription",
           foreign_key: :processor_plan

  # Validations
  validates :name, presence: true, uniqueness: true
  validates :monthly_price_cents, numericality: {
    greater_than_or_equal_to: 0
  }
  validates :monthly_tokens, numericality: {
    greater_than_or_equal_to: 0
  }
  validates :status, presence: true

  # Scopes
  scope :active, -> { where(status: :active) }
  scope :legacy, -> { where(status: :legacy) }
  scope :available_for_selection, -> { active }

  # Business Logic
  def free_plan?
    monthly_price_cents.zero?
  end

  def allows_token_usage?
    !inactive?
  end

  def monthly_price_dollars
    monthly_price_cents / 100.0
  end

  def price_per_token
    return 0 if monthly_tokens.zero?
    monthly_price_cents.to_f / monthly_tokens
  end
end
```

### Credit Model

```ruby
class Credit < ApplicationRecord
  belongs_to :account

  # Enums
  enum :purchase_type, {
    subscription_included: 0,
    purchased: 1,
    bonus: 2
  }

  # Validations
  validates :amount_tokens, numericality: { greater_than: 0 }
  validates :cost_cents, numericality: { greater_than_or_equal_to: 0 }

  # Scopes
  scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :expired, -> { where("expires_at <= ?", Time.current) }
  scope :by_account, ->(account) { where(account: account) }

  # Business Logic
  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def active?
    !expired?
  end
end
```

### TokenUsage Model

```ruby
class TokenUsage < ApplicationRecord
  belongs_to :account
  belongs_to :chat
  belongs_to :message

  # Validations
  validates :model_id, presence: true
  validates :input_tokens, :output_tokens, :total_tokens,
            numericality: { greater_than_or_equal_to: 0 }

  # Scopes
  scope :for_account, ->(account) { where(account: account) }
  scope :for_chat, ->(chat) { where(chat: chat) }
  scope :today, -> { where(created_at: Time.current.all_day) }
  scope :this_month, -> { where(created_at: Time.current.all_month) }
  scope :by_model, ->(model_id) { where(model_id: model_id) }

  # Callbacks
  before_validation :calculate_total_tokens
  before_validation :calculate_cost

  private

  def calculate_total_tokens
    self.total_tokens = input_tokens.to_i + output_tokens.to_i
  end

  def calculate_cost
    return unless model_id.present?

    model_info = RubyLLM.models.find(model_id)
    return unless model_info&.pricing

    input_cost = (input_tokens.to_f / 1_000_000) * model_info.pricing[:input]
    output_cost = (output_tokens.to_f / 1_000_000) * model_info.pricing[:output]

    self.cost_cents = ((input_cost + output_cost) * 100).round(2)
  end
end
```

### Account Extensions

```ruby
# app/models/concerns/account/tokenable.rb
module Account::Tokenable
  extend ActiveSupport::Concern

  included do
    # Pay gem integration
    pay_customer stripe_attributes: :stripe_attributes

    # Associations
    has_many :credits, dependent: :destroy
    has_many :token_usages, dependent: :destroy
    has_one :active_subscription, -> { active },
            class_name: "Pay::Subscription"
    has_one :plan, through: :active_subscription, source: :plan

    # Callbacks
    after_create :initialize_free_plan, if: :personal?
    after_commit :check_auto_recharge, if: :should_auto_recharge?
  end

  # Token balance management
  def consume_tokens!(tokens, message:)
    raise InsufficientTokensError unless has_tokens?(tokens)

    transaction do
      update!(token_balance: token_balance - tokens)

      TokenUsage.create!(
        account: self,
        chat: message.chat,
        message: message,
        model_id: message.model_id,
        input_tokens: message.input_tokens,
        output_tokens: message.output_tokens,
        total_tokens: tokens,
        cost_cents: message.cost_cents
      )
    end
  end

  def add_tokens!(amount, purchase_type: :purchased, cost_cents: 0, expires_at: nil)
    transaction do
      Credit.create!(
        account: self,
        amount_tokens: amount,
        cost_cents: cost_cents,
        purchase_type: purchase_type,
        expires_at: expires_at
      )

      update!(token_balance: token_balance + amount)
    end
  end

  def has_tokens?(amount = 1)
    token_balance >= amount && plan&.allows_token_usage?
  end

  def tokens_remaining
    token_balance
  end

  # Subscription management
  def subscribe_to_plan!(plan, payment_method_token: nil)
    raise ArgumentError, "Plan must be active" unless plan.active?

    transaction do
      if payment_method_token
        payment_processor.update_payment_method(payment_method_token)
      end

      payment_processor.subscribe(
        name: "default",
        plan: plan.stripe_price_id
      )

      # Add monthly tokens
      add_tokens!(
        plan.monthly_tokens,
        purchase_type: :subscription_included,
        expires_at: 1.month.from_now
      )
    end
  end

  def cancel_subscription!
    return unless active_subscription

    active_subscription.cancel
  end

  # Auto-recharge
  def configure_auto_recharge!(enabled:, amount_cents: nil, threshold_tokens: nil, limit_cents: nil)
    update!(
      auto_recharge_enabled: enabled,
      auto_recharge_amount_cents: amount_cents,
      auto_recharge_threshold_tokens: threshold_tokens,
      auto_recharge_limit_cents: limit_cents
    )
  end

  def trigger_auto_recharge!
    return unless auto_recharge_enabled?
    return if auto_recharge_limit_reached?

    tokens_to_purchase = calculate_tokens_for_purchase(auto_recharge_amount_cents)

    payment_processor.charge(auto_recharge_amount_cents)

    add_tokens!(
      tokens_to_purchase,
      purchase_type: :purchased,
      cost_cents: auto_recharge_amount_cents
    )
  end

  private

  def stripe_attributes
    {
      address: {
        city: billing_city,
        country: billing_country
      },
      metadata: {
        account_id: id,
        account_type: account_type
      }
    }
  end

  def initialize_free_plan
    free_plan = Plan.find_by(monthly_price_cents: 0, status: :active)
    return unless free_plan

    add_tokens!(
      free_plan.monthly_tokens,
      purchase_type: :subscription_included
    )
  end

  def should_auto_recharge?
    auto_recharge_enabled? &&
    token_balance <= auto_recharge_threshold_tokens.to_i &&
    !auto_recharge_limit_reached?
  end

  def auto_recharge_limit_reached?
    return false unless auto_recharge_limit_cents

    total_auto_recharge_spent = credits
      .where(purchase_type: :purchased)
      .sum(:cost_cents)

    total_auto_recharge_spent >= auto_recharge_limit_cents
  end

  def calculate_tokens_for_purchase(amount_cents)
    # Use average cost per token from recent usage
    recent_usage = token_usages.where("created_at > ?", 30.days.ago)

    return 0 if recent_usage.empty?

    avg_cost_per_token = recent_usage.average(:cost_cents).to_f /
                         recent_usage.average(:total_tokens).to_f

    (amount_cents / avg_cost_per_token).to_i
  end

  def check_auto_recharge
    AutoRechargeJob.perform_later(self) if should_auto_recharge?
  end

  class InsufficientTokensError < StandardError; end
end

# Include in Account model
class Account < ApplicationRecord
  include Account::Tokenable
  # ... existing code
end
```

### Message Extensions

```ruby
# app/models/concerns/message/tokenable.rb
module Message::Tokenable
  extend ActiveSupport::Concern

  included do
    # Callbacks
    after_commit :record_token_usage, on: :update,
                 if: -> { saved_change_to_input_tokens? || saved_change_to_output_tokens? }
  end

  def total_tokens
    input_tokens.to_i + output_tokens.to_i
  end

  def calculate_cost_cents
    return 0 unless model_id.present?

    model_info = RubyLLM.models.find(model_id)
    return 0 unless model_info&.pricing

    input_cost = (input_tokens.to_f / 1_000_000) * model_info.pricing[:input]
    output_cost = (output_tokens.to_f / 1_000_000) * model_info.pricing[:output]

    ((input_cost + output_cost) * 100).round(2)
  end

  private

  def record_token_usage
    return unless role == "assistant" && total_tokens.positive?

    self.cost_cents = calculate_cost_cents
    save if cost_cents_changed?

    account.consume_tokens!(total_tokens, message: self)
  rescue Account::InsufficientTokensError => e
    Rails.logger.error "Token consumption failed: #{e.message}"
    # This shouldn't happen as we check before processing
  end
end

# Include in Message model
class Message < ApplicationRecord
  include Message::Tokenable
  # ... existing code
end
```

## Concern: TokenGating

```ruby
# app/controllers/concerns/token_gating.rb
module TokenGating
  extend ActiveSupport::Concern

  included do
    before_action :check_token_availability, only: [:create]
  end

  private

  def check_token_availability
    account = current_account

    unless account.has_tokens?
      respond_to_insufficient_tokens(account)
      return false
    end

    unless account.plan&.allows_token_usage?
      respond_to_inactive_plan(account)
      return false
    end

    true
  end

  def respond_to_insufficient_tokens(account)
    message = if account.auto_recharge_enabled?
      "Auto-recharge is processing. Please try again in a moment."
    else
      "Insufficient tokens. Please purchase more credits or upgrade your plan."
    end

    respond_to do |format|
      format.html { redirect_back_or_to account_chats_path(account), alert: message }
      format.json { render json: { error: message }, status: :payment_required }
    end
  end

  def respond_to_inactive_plan(account)
    message = "Your plan is no longer active. Please upgrade to continue using AI features."

    respond_to do |format|
      format.html { redirect_back_or_to account_chats_path(account), alert: message }
      format.json { render json: { error: message }, status: :payment_required }
    end
  end
end

# app/controllers/chats_controller.rb
class ChatsController < ApplicationController
  include TokenGating
  # ... existing code
end

# app/controllers/messages_controller.rb
class MessagesController < ApplicationController
  include TokenGating
  # ... existing code
end
```

## Background Jobs

### AutoRechargeJob

```ruby
# app/jobs/auto_recharge_job.rb
class AutoRechargeJob < ApplicationJob
  queue_as :default

  def perform(account)
    return unless account.should_auto_recharge?

    account.trigger_auto_recharge!
  rescue Stripe::CardError => e
    Rails.logger.error "Auto-recharge failed for account #{account.id}: #{e.message}"
    AccountMailer.auto_recharge_failed(account, e.message).deliver_later
  end
end
```

### MonthlyTokenAllocationJob

```ruby
# app/jobs/monthly_token_allocation_job.rb
class MonthlyTokenAllocationJob < ApplicationJob
  queue_as :default

  def perform
    Pay::Subscription.active.find_each do |subscription|
      account = subscription.customer
      plan = Plan.find_by(stripe_price_id: subscription.processor_plan)

      next unless account && plan

      account.add_tokens!(
        plan.monthly_tokens,
        purchase_type: :subscription_included,
        expires_at: 1.month.from_now
      )
    end
  end
end
```

## Updated AiResponseJob

```ruby
class AiResponseJob < ApplicationJob
  STREAM_DEBOUNCE_INTERVAL = 0.2.seconds

  def perform(chat)
    unless chat.is_a?(Chat)
      raise ArgumentError, "Expected a Chat object, got #{chat.class}"
    end

    # Check token availability before processing
    account = chat.account
    unless account.has_tokens?
      Rails.logger.warn "Chat #{chat.id} skipped: insufficient tokens"
      return
    end

    @chat = chat
    @ai_message = nil
    @stream_buffer = +""
    @last_stream_flush_at = nil

    chat.on_new_message do
      @ai_message = chat.messages.order(:created_at).last
      @ai_message.update!(streaming: true) if @ai_message
    end

    chat.on_end_message do |ruby_llm_message|
      finalize_message!(ruby_llm_message)
    end

    chat.complete do |chunk|
      next unless chunk.content && @ai_message
      enqueue_stream_chunk(chunk.content)
    end
  rescue RubyLLM::ModelNotFoundError => e
    @model_not_found_error = true
    error "Model not found: #{e.message}, trying again..."
    RubyLLM.models.refresh!
    retry_job unless @model_not_found_error
  rescue Account::InsufficientTokensError => e
    Rails.logger.error "Token consumption failed during AI response: #{e.message}"
    @ai_message&.update(content: "Error: Insufficient tokens to complete response")
  ensure
    flush_stream_buffer(force: true)
    @ai_message&.stop_streaming if @ai_message&.streaming?
  end

  private

  def finalize_message!(ruby_llm_message)
    @ai_message ||= @chat.messages.order(:created_at).last
    return unless @ai_message

    flush_stream_buffer(force: true)

    @ai_message.update!({
      content: extract_message_content(ruby_llm_message.content),
      model_id: ruby_llm_message.model_id,
      input_tokens: ruby_llm_message.input_tokens,
      output_tokens: ruby_llm_message.output_tokens,
      cost_cents: @ai_message.calculate_cost_cents,
      streaming: false
    })

    # Token consumption happens in Message callback
  end

  # ... rest of existing methods
end
```

## Migration Strategy

### Step 1: Install Pay Gem

```ruby
# Gemfile
gem "pay", "~> 11.1"
gem "stripe", "~> 15.3"

# Terminal
bundle install
bin/rails pay:install:migrations
```

### Step 2: Create Plan Migrations

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_plans.rb
class CreatePlans < ActiveRecord::Migration[8.0]
  def change
    create_table :plans do |t|
      t.string :name, null: false
      t.string :stripe_price_id
      t.integer :status, null: false, default: 0
      t.decimal :monthly_price_cents, precision: 10, scale: 2, default: 0
      t.integer :monthly_tokens, null: false, default: 0
      t.text :description
      t.jsonb :metadata, default: {}
      t.timestamps

      t.index :status
      t.index :stripe_price_id, unique: true
    end
  end
end
```

### Step 3: Create Credits Migration

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_credits.rb
class CreateCredits < ActiveRecord::Migration[8.0]
  def change
    create_table :credits do |t|
      t.references :account, null: false, foreign_key: true
      t.integer :amount_tokens, null: false
      t.integer :cost_cents, null: false
      t.string :purchase_type, null: false
      t.datetime :expires_at
      t.timestamps

      t.index [:account_id, :created_at]
      t.index :expires_at
    end
  end
end
```

### Step 4: Create Token Usage Migration

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_token_usages.rb
class CreateTokenUsages < ActiveRecord::Migration[8.0]
  def change
    create_table :token_usages do |t|
      t.references :account, null: false, foreign_key: true
      t.references :chat, null: false, foreign_key: true
      t.references :message, null: false, foreign_key: true
      t.string :model_id, null: false
      t.integer :input_tokens, null: false, default: 0
      t.integer :output_tokens, null: false, default: 0
      t.integer :total_tokens, null: false, default: 0
      t.decimal :cost_cents, precision: 10, scale: 2
      t.datetime :created_at, null: false

      t.index [:account_id, :created_at]
      t.index [:chat_id, :created_at]
      t.index :model_id
    end
  end
end
```

### Step 5: Add Token Columns to Accounts

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_token_fields_to_accounts.rb
class AddTokenFieldsToAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :accounts, :token_balance, :integer, default: 0, null: false
    add_column :accounts, :auto_recharge_enabled, :boolean, default: false
    add_column :accounts, :auto_recharge_amount_cents, :integer
    add_column :accounts, :auto_recharge_threshold_tokens, :integer
    add_column :accounts, :auto_recharge_limit_cents, :integer

    add_index :accounts, :token_balance
  end
end
```

### Step 6: Add Cost to Messages

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_cost_to_messages.rb
class AddCostToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :cost_cents, :decimal, precision: 10, scale: 2
    add_index :messages, :cost_cents
  end
end
```

## Seed Data

```ruby
# db/seeds.rb

# Create default plans
Plan.create!([
  {
    name: "Free",
    status: :active,
    monthly_price_cents: 0,
    monthly_tokens: 10_000,
    description: "Perfect for trying out the platform"
  },
  {
    name: "Starter",
    stripe_price_id: "price_starter_monthly",
    status: :active,
    monthly_price_cents: 2000, # $20
    monthly_tokens: 1_000_000,
    description: "Great for light usage"
  },
  {
    name: "Pro",
    stripe_price_id: "price_pro_monthly",
    status: :active,
    monthly_price_cents: 10000, # $100
    monthly_tokens: 10_000_000,
    description: "For power users"
  },
  {
    name: "Enterprise",
    stripe_price_id: "price_enterprise_monthly",
    status: :active,
    monthly_price_cents: 20000, # $200
    monthly_tokens: 50_000_000,
    description: "Unlimited usage for teams"
  }
])
```

## Implementation Checklist

### Phase 1: Core Infrastructure
- [ ] Install Pay gem and run migrations
- [ ] Create Plan model and migration
- [ ] Create Credit model and migration
- [ ] Create TokenUsage model and migration
- [ ] Add token fields to accounts migration
- [ ] Add cost field to messages migration
- [ ] Run all migrations

### Phase 2: Model Logic
- [ ] Implement Plan model with validations and scopes
- [ ] Implement Credit model with expiration logic
- [ ] Implement TokenUsage model with cost calculation
- [ ] Create Account::Tokenable concern
- [ ] Create Message::Tokenable concern
- [ ] Add Pay integration to Account model

### Phase 3: Token Gating
- [ ] Create TokenGating concern for controllers
- [ ] Include TokenGating in ChatsController
- [ ] Include TokenGating in MessagesController
- [ ] Update AiResponseJob to check tokens before processing
- [ ] Add error handling for insufficient tokens

### Phase 4: Background Jobs
- [ ] Create AutoRechargeJob
- [ ] Create MonthlyTokenAllocationJob
- [ ] Schedule MonthlyTokenAllocationJob (1st of month)
- [ ] Test auto-recharge flow

### Phase 5: Webhooks & Payment Flow
- [ ] Configure Stripe webhooks
- [ ] Test subscription creation flow
- [ ] Test one-time charge flow
- [ ] Test subscription cancellation
- [ ] Test auto-recharge

### Phase 6: Testing & Polish
- [ ] Write model tests for Plan
- [ ] Write model tests for Credit
- [ ] Write model tests for TokenUsage
- [ ] Write controller tests for token gating
- [ ] Write integration tests for payment flows
- [ ] Add logging for token consumption
- [ ] Add admin seed data for plans

## Testing Strategy

### Unit Tests

```ruby
# test/models/plan_test.rb
class PlanTest < ActiveSupport::TestCase
  test "active scope returns only active plans" do
    active = Plan.create!(name: "Active", status: :active, monthly_tokens: 1000)
    legacy = Plan.create!(name: "Legacy", status: :legacy, monthly_tokens: 1000)

    assert_includes Plan.active, active
    assert_not_includes Plan.active, legacy
  end

  test "allows_token_usage returns false for inactive plans" do
    plan = Plan.create!(name: "Inactive", status: :inactive, monthly_tokens: 1000)
    assert_not plan.allows_token_usage?
  end
end

# test/models/account_test.rb
class AccountTest < ActiveSupport::TestCase
  test "consume_tokens decreases balance" do
    account = accounts(:one)
    account.update!(token_balance: 1000)

    message = messages(:one)
    message.update!(input_tokens: 50, output_tokens: 50)

    account.consume_tokens!(100, message: message)
    assert_equal 900, account.reload.token_balance
  end

  test "consume_tokens raises error when insufficient" do
    account = accounts(:one)
    account.update!(token_balance: 50)

    message = messages(:one)

    assert_raises Account::InsufficientTokensError do
      account.consume_tokens!(100, message: message)
    end
  end
end
```

### Integration Tests

```ruby
# test/integration/token_gating_test.rb
class TokenGatingTest < ActionDispatch::IntegrationTest
  test "cannot create message without tokens" do
    account = accounts(:one)
    account.update!(token_balance: 0)
    chat = chats(:one)

    sign_in users(:one)

    post account_chat_messages_path(account, chat), params: {
      message: { content: "Hello" }
    }

    assert_redirected_to account_chat_path(account, chat)
    assert_match /insufficient tokens/i, flash[:alert]
  end

  test "can create message with sufficient tokens" do
    account = accounts(:one)
    account.update!(token_balance: 1000)
    chat = chats(:one)

    sign_in users(:one)

    assert_difference "Message.count", 1 do
      post account_chat_messages_path(account, chat), params: {
        message: { content: "Hello" }
      }
    end
  end
end
```

## Error Handling

### Custom Errors

```ruby
# app/models/account.rb
class Account < ApplicationRecord
  class InsufficientTokensError < StandardError
    def initialize(account)
      @account = account
      super("Account #{account.id} has insufficient tokens")
    end
  end

  class InactivePlanError < StandardError
    def initialize(account)
      @account = account
      super("Account #{account.id} plan is inactive")
    end
  end
end
```

### Error Handling in Controllers

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  rescue_from Account::InsufficientTokensError, with: :handle_insufficient_tokens
  rescue_from Account::InactivePlanError, with: :handle_inactive_plan

  private

  def handle_insufficient_tokens(exception)
    respond_to do |format|
      format.html {
        redirect_to account_billing_path(current_account),
        alert: "You've run out of tokens. Please add more credits."
      }
      format.json {
        render json: { error: exception.message },
        status: :payment_required
      }
    end
  end

  def handle_inactive_plan(exception)
    respond_to do |format|
      format.html {
        redirect_to account_plans_path(current_account),
        alert: "Your plan is inactive. Please upgrade to continue."
      }
      format.json {
        render json: { error: exception.message },
        status: :payment_required
      }
    end
  end
end
```

## Potential Edge Cases

1. **Race Conditions**: Token consumption during concurrent requests
   - Solution: Use database transactions and row-level locking
   - `account.with_lock { account.consume_tokens!(...) }`

2. **Token Calculation Accuracy**: Different models have different costs
   - Solution: Use RubyLLM Model Registry for accurate pricing
   - Fallback to conservative estimates if model not found

3. **Subscription Renewal**: Tokens added before webhook processed
   - Solution: Use Pay's webhook handlers
   - Idempotent token allocation based on subscription ID

4. **Auto-recharge Limits**: Preventing runaway charges
   - Solution: Track total auto-recharge spend per account
   - Hard limit in database, checked before each auto-recharge

5. **Plan Migration**: Users switching plans mid-month
   - Solution: Prorate tokens based on days remaining
   - Legacy plans remain functional for existing users

6. **Token Expiration**: Subscription tokens expire monthly
   - Solution: Track expiration on Credit records
   - Scheduled job to clean up expired credits

7. **Refunds**: User wants refund for unused tokens
   - Solution: Calculate unused token value
   - Issue Stripe refund via Pay gem

## Future Enhancements

### Admin Panel (Future Phase)
- Plan management UI
- Token usage analytics dashboard
- Account balance monitoring
- Pricing margin configuration

### Advanced Features (Future Phase)
- Volume discounts for high usage
- Team-based token pooling
- Reserved capacity pricing
- Model-specific rate limiting

### Optimizations (Future Phase)
- Token usage caching
- Batch token allocation
- Predictive auto-recharge
- Usage pattern analysis

## Success Criteria

1. **Functional**
   - [ ] Accounts can subscribe to plans
   - [ ] Token consumption is tracked accurately
   - [ ] Auto-recharge works reliably
   - [ ] Token gating prevents usage when balance is zero
   - [ ] All payment flows work end-to-end

2. **Code Quality**
   - [ ] Follows Rails conventions strictly
   - [ ] No service objects or over-engineering
   - [ ] All business logic in models
   - [ ] Controllers remain thin
   - [ ] Tests provide good coverage

3. **Performance**
   - [ ] Token checks add minimal latency
   - [ ] Database queries are optimized
   - [ ] Background jobs process efficiently
   - [ ] Webhooks handled promptly

4. **User Experience**
   - [ ] Clear error messages for token issues
   - [ ] Seamless auto-recharge
   - [ ] Transparent token usage tracking
   - [ ] Flexible plan options

## The Rails-Worthiness Test

This implementation passes DHH's standards because:

1. **Convention over Configuration**: Uses Rails associations, callbacks, and concerns
2. **No Paradigm**: Model methods are appropriately OO, queries are functional
3. **Conceptual Compression**: Token consumption abstracted into clean model methods
4. **Programmer Happiness**: Code reads like English, obvious what it does
5. **Fat Models**: All business logic in models where it belongs
6. **Omakase Menu**: Follows Rails' opinionated path with Pay gem integration

Would DHH approve? Yes. This is Rails code that belongs in the guides.
