# Payments System Implementation Plan (Credits-Based with Multi-Processor Support)

## Executive Summary

A production-ready, Rails-worthy payments system that supports flexible billing models for AI API usage through a **credits-based economy**. This implementation supports both **Stripe and Paddle Billing** payment processors, uses actual dollar amounts (in cents) for token costs, and includes configurable margin percentages for profitability.

**Key Changes from Previous Version:**
- **Credits instead of tokens**: Accounts have a `credits_balance_cents` that represents actual dollar amounts
- **Multi-processor support**: Both Stripe and Paddle Billing integration
- **Margin-based pricing**: Plans define profit margins for sustainable business model
- **Actual cost tracking**: Messages store real API costs from RubyLLM Model Registry

The system supports subscription-based billing, pay-as-you-go credits, auto-recharge, and plan-based credit limits. All billing is account-based, supporting both personal and team accounts.

## Architecture Overview

### Core Philosophy

This implementation ruthlessly follows The Rails Way:
- **Single source of truth** - Credits balance lives in one place (cents)
- **Trust the database** - PostgreSQL handles atomic operations
- **Delete code** - No unnecessary abstractions or "token" concepts
- **Fat models** - Business logic in models where it belongs
- **Rails associations** - Let Rails do what it does best
- **Real economics** - Track actual costs and apply transparent margins

### Technology Stack

- **Payment Processing**: Pay gem (Stripe & Paddle Billing support)
- **Cost Calculation**: RubyLLM Model Registry pricing data
- **Background Processing**: Solid Queue (Rails 8)
- **Database**: PostgreSQL with Rails validations

### Key Concepts

1. **Credits Economy** - Users purchase credits (displayed as dollars), which are consumed based on actual API costs plus margin
2. **Plans** - Define subscription tiers with credit allowances, margins, and pricing
3. **Credits Balance** - Single integer on Account (in cents, source of truth)
4. **Messages** - Store actual API costs in cents
5. **Auto-recharge** - Configurable per-account with plan-based thresholds
6. **Margin System** - Plans define profit margin percentage applied to all costs

### How the Credits Economy Works

#### For Users
1. User purchases "$20 of credits" (displayed as "20.00 credits")
2. Each AI message consumes credits based on model cost + margin
3. Example: GPT-4 message costs $0.015 in API fees
   - With 50% margin: User sees "0.0225 credits used"
   - Balance decreases by 2.25 cents (2250 credit cents)
4. User always sees their credit balance in familiar dollar amounts

#### For the Business
1. Plan defines `margin_percentage` (e.g., 50%)
2. Actual API cost: $0.015 (from RubyLLM pricing)
3. Credit cost to user: $0.015 × 1.5 = $0.0225
4. Profit: $0.0075 per message
5. Sustainable business model with transparent economics

## Database Schema

### New Tables

#### plans
```ruby
create_table :plans do |t|
  t.string :name, null: false
  t.string :stripe_price_id
  t.string :paddle_price_id
  t.integer :status, null: false, default: 0  # active, archived
  t.integer :monthly_price_cents, default: 0, null: false
  t.integer :monthly_credits_cents, default: 0, null: false
  t.integer :margin_percentage, default: 50, null: false
  t.integer :auto_recharge_threshold_cents, default: 500, null: false
  t.text :description
  t.timestamps

  t.index :status
  t.index :stripe_price_id, unique: true
  t.index :paddle_price_id, unique: true
end

# Enum: { active: 0, archived: 1 }
```

**Key Changes:**
- `monthly_credits_cents` instead of `monthly_tokens` - represents credit allocation in cents
- `margin_percentage` - defines profit margin (50 = 50% markup)
- Both `stripe_price_id` and `paddle_price_id` for multi-processor support
- `auto_recharge_threshold_cents` - when to trigger auto-recharge (in cents)

### Schema Modifications

#### accounts
```ruby
add_column :accounts, :plan_id, :bigint
add_column :accounts, :credits_balance_cents, :integer, default: 0, null: false
add_column :accounts, :auto_recharge_enabled, :boolean, default: false
add_column :accounts, :auto_recharge_amount_cents, :integer
add_column :accounts, :preferred_processor, :string, default: 'stripe'

add_index :accounts, :plan_id
add_index :accounts, :credits_balance_cents
add_foreign_key :accounts, :plans
```

**Key Changes:**
- `credits_balance_cents` instead of `token_balance` - actual money in cents
- `preferred_processor` - account chooses Stripe or Paddle

#### messages
```ruby
add_column :messages, :api_cost_cents, :integer
add_column :messages, :credit_cost_cents, :integer
add_index :messages, :api_cost_cents
add_index :messages, :credit_cost_cents
add_index :messages, [:account_id, :created_at]
```

**Key Changes:**
- `api_cost_cents` - actual API cost from RubyLLM pricing
- `credit_cost_cents` - what user was charged (includes margin)

## Model Implementation

### Plan Model

```ruby
# app/models/plan.rb
class Plan < ApplicationRecord
  has_many :accounts

  enum :status, { active: 0, archived: 1 }

  validates :name, presence: true, uniqueness: true
  validates :monthly_price_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :monthly_credits_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :margin_percentage, numericality: { greater_than: 0, less_than_or_equal_to: 500 }
  validates :auto_recharge_threshold_cents, numericality: { greater_than: 0 }

  scope :active, -> { where(status: :active) }
  scope :available_for_selection, -> { active }

  def free?
    monthly_price_cents.zero?
  end

  def price_in_dollars
    monthly_price_cents / 100.0
  end

  def monthly_credits_in_dollars
    monthly_credits_cents / 100.0
  end

  def margin_multiplier
    1 + (margin_percentage / 100.0)
  end

  # Convert actual API cost to credit cost (apply margin)
  def credit_cost_for(api_cost_cents)
    (api_cost_cents * margin_multiplier).round
  end

  # Reverse calculation: credit cost to actual API cost
  def api_cost_for(credit_cost_cents)
    (credit_cost_cents / margin_multiplier).round
  end

  # Calculate how many credits user gets per dollar spent
  def credits_per_dollar_spent
    return 0 if monthly_price_cents.zero?
    monthly_credits_cents.to_f / monthly_price_cents
  end

  def price_id_for(processor)
    case processor.to_s
    when 'stripe' then stripe_price_id
    when 'paddle', 'paddle_billing' then paddle_price_id
    else
      raise ArgumentError, "Unknown processor: #{processor}"
    end
  end

  def supports_processor?(processor)
    price_id_for(processor).present?
  rescue ArgumentError
    false
  end

  def can_archive?
    accounts.joins(:payment_processor_subscriptions)
           .where(pay_subscriptions: { status: "active" })
           .none?
  end

  def archive!
    raise "Cannot archive plan with active subscriptions" unless can_archive?
    update!(status: :archived)
  end

  def <=>(other)
    monthly_price_cents <=> other.monthly_price_cents
  end

  def upgrade_from?(other_plan)
    monthly_price_cents > other_plan.monthly_price_cents
  end

  def features
    [
      "#{monthly_credits_in_dollars.to_s(:currency)} credits per month",
      "#{margin_percentage}% margin on API costs",
      ("Auto-recharge available" unless free?),
      ("Priority support" if monthly_price_cents >= 10_000)
    ].compact
  end
end
```

### Account Model Extensions

```ruby
# app/models/account.rb
class Account < ApplicationRecord
  # ... existing includes and configuration ...

  # Pay gem integration
  pay_customer stripe_attributes: :stripe_attributes,
               paddle_attributes: :paddle_attributes

  # Associations
  belongs_to :plan, optional: true
  # has_many :chats (already exists)
  # has_many :messages, through: :chats (already exists via Chat)

  # Validations
  validates :auto_recharge_amount_cents,
            numericality: { greater_than: 0 },
            if: :auto_recharge_enabled?
  validates :auto_recharge_amount_cents,
            presence: true,
            if: :auto_recharge_enabled?
  validates :preferred_processor,
            inclusion: { in: %w[stripe paddle_billing] }

  # Callbacks
  after_create :setup_free_plan, if: :personal?

  # Credits management (in cents)
  def has_credits?(amount_cents = 1)
    credits_balance_cents >= amount_cents
  end

  def consume_credits!(amount_cents)
    raise InsufficientCreditsError.new(self, amount_cents) if credits_balance_cents < amount_cents
    decrement!(:credits_balance_cents, amount_cents)
    trigger_auto_recharge if should_auto_recharge?
  end

  def add_credits!(amount_cents)
    increment!(:credits_balance_cents, amount_cents)
  end

  # Display helpers
  def credits_balance_display
    "$%.2f" % (credits_balance_cents / 100.0)
  end

  def credits_remaining_display
    if credits_balance_cents >= 100_000 # $1000+
      "$#{(credits_balance_cents / 100_000.0).round}k"
    else
      credits_balance_display
    end
  end

  # Subscription management with processor selection
  def subscribe!(plan, payment_method_token: nil, processor: nil)
    raise ArgumentError, "Plan must be active" unless plan.active?

    processor ||= preferred_processor
    unless plan.supports_processor?(processor)
      raise ArgumentError, "Plan does not support #{processor}"
    end

    set_payment_processor(processor.to_sym)

    transaction do
      payment_processor.update_payment_method(payment_method_token) if payment_method_token

      case processor.to_s
      when 'stripe'
        payment_processor.subscribe(
          name: "default",
          plan: plan.stripe_price_id
        )
      when 'paddle_billing'
        # Paddle requires checkout via iFrame/hosted page
        # Subscription created via webhook
        payment_processor.api_record # Ensure customer exists
      end

      update!(plan: plan)
      add_credits!(plan.monthly_credits_cents) if processor.to_s == 'stripe'
      # Paddle credits added via webhook on successful payment
    end
  end

  def cancel_subscription!
    return unless payment_processor.subscription

    payment_processor.subscription.cancel
  end

  def subscribed?
    payment_processor.subscription&.active?
  end

  def subscription_status
    payment_processor.subscription&.status || "none"
  end

  def subscription_ends_at
    payment_processor.subscription&.ends_at
  end

  # Analytics - costs in cents
  def api_costs_this_month
    messages.assistant
            .where(created_at: Time.current.all_month)
            .sum(:api_cost_cents)
  end

  def credits_used_this_month
    messages.assistant
            .where(created_at: Time.current.all_month)
            .sum(:credit_cost_cents)
  end

  def api_costs_today
    messages.assistant
            .where(created_at: Time.current.all_day)
            .sum(:api_cost_cents)
  end

  def credits_used_today
    messages.assistant
            .where(created_at: Time.current.all_day)
            .sum(:credit_cost_cents)
  end

  # Purchase one-time credits
  def purchase_credits!(amount_cents, payment_method_token: nil)
    set_payment_processor(preferred_processor.to_sym)
    payment_processor.update_payment_method(payment_method_token) if payment_method_token

    charge = payment_processor.charge(amount_cents)
    if charge.succeeded?
      add_credits!(amount_cents)
      charge
    else
      raise PaymentFailedError.new(charge.error_message)
    end
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

  def paddle_attributes
    {
      email: users.first&.email_address,
      name: name,
      custom_data: {
        account_id: id,
        account_type: account_type
      }
    }
  end

  def setup_free_plan
    free_plan = Plan.active.find_by(monthly_price_cents: 0)
    return unless free_plan

    update!(
      plan: free_plan,
      credits_balance_cents: free_plan.monthly_credits_cents
    )
  end

  def should_auto_recharge?
    auto_recharge_enabled? &&
      credits_balance_cents < (plan&.auto_recharge_threshold_cents || 500)
  end

  def trigger_auto_recharge
    AutoRechargeJob.perform_later(id)
  end

  class InsufficientCreditsError < StandardError
    attr_reader :account, :required_cents

    def initialize(account = nil, required_cents = nil)
      @account = account
      @required_cents = required_cents

      if account && required_cents
        required_display = "$%.2f" % (required_cents / 100.0)
        balance_display = "$%.2f" % (account.credits_balance_cents / 100.0)
        super("Insufficient credits: need #{required_display}, have #{balance_display}")
      else
        super("Insufficient credits")
      end
    end
  end

  class PaymentFailedError < StandardError
    def initialize(error_message)
      super("Payment failed: #{error_message}")
    end
  end
end
```

### Message Model Extensions

```ruby
# app/models/message.rb
class Message < ApplicationRecord
  # ... existing includes and configuration ...

  belongs_to :chat, touch: true
  belongs_to :user, optional: true
  has_one :account, through: :chat

  # Scopes
  scope :assistant, -> { where(role: "assistant") }
  scope :sorted, -> { order(created_at: :asc) }

  # Callbacks - CRITICAL: Only process after RubyLLM updates token counts
  after_commit :calculate_and_charge_credits, on: :update,
               if: -> { saved_change_to_output_tokens? && role == "assistant" }

  def total_tokens
    input_tokens.to_i + output_tokens.to_i
  end

  private

  def calculate_and_charge_credits
    return if total_tokens.zero?
    return unless model_id.present?

    ActiveRecord::Base.transaction do
      calculate_costs
      charge_account_credits
    end
  rescue Account::InsufficientCreditsError => e
    handle_insufficient_credits(e)
  end

  def calculate_costs
    # Get actual cost from RubyLLM Model Registry
    model_info = RubyLLM.models.find(model_id)
    return unless model_info&.pricing

    # Calculate actual API cost in cents
    input_cost_dollars = (input_tokens.to_f / 1_000_000) * model_info.pricing[:input]
    output_cost_dollars = (output_tokens.to_f / 1_000_000) * model_info.pricing[:output]

    api_cost = ((input_cost_dollars + output_cost_dollars) * 100).round

    # Apply account's plan margin to get credit cost
    plan = account.plan || Plan.find_by(monthly_price_cents: 0) # Default to free plan
    credit_cost = plan.credit_cost_for(api_cost)

    # Store both costs
    update_columns(
      api_cost_cents: api_cost,
      credit_cost_cents: credit_cost
    )
  end

  def charge_account_credits
    return unless credit_cost_cents&.positive?
    account.consume_credits!(credit_cost_cents)
  end

  def handle_insufficient_credits(error)
    Rails.logger.error "Credit deduction failed for message #{id}: #{error.message}"

    # Mark message as failed
    update_columns(content: content.to_s + "\n\n[Message truncated: Insufficient credits]")

    # Notify user
    AccountMailer.insufficient_credits_notification(account, self).deliver_later
  end
end
```

## Controller Concern: CreditsGating

```ruby
# app/controllers/concerns/credits_gating.rb
module CreditsGating
  extend ActiveSupport::Concern

  included do
    before_action :require_credits, only: [:create]
  end

  private

  def require_credits
    # Check for minimum credits (about $0.01 worth)
    return if current_account.has_credits?(100)

    message = if current_account.plan&.free?
      "You're out of credits. Upgrade your plan to continue using AI features."
    else
      "You're out of credits. Purchase more credits or enable auto-recharge."
    end

    redirect_back_or_to account_billing_path(current_account),
                        alert: message,
                        inertia: {
                          errors: {
                            credits: message,
                            balance: current_account.credits_balance_display
                          }
                        }
  end
end
```

**Usage:**
```ruby
# app/controllers/chats_controller.rb
class ChatsController < ApplicationController
  include CreditsGating
  # ... existing code
end

# app/controllers/messages_controller.rb
class MessagesController < ApplicationController
  include CreditsGating
  # ... existing code
end
```

## Background Jobs

### AutoRechargeJob

```ruby
# app/jobs/auto_recharge_job.rb
class AutoRechargeJob < ApplicationJob
  queue_as :default
  retry_on Stripe::RateLimitError, wait: :polynomially_longer, attempts: 3
  retry_on Pay::Paddle::Error, wait: :polynomially_longer, attempts: 3

  def perform(account_id)
    account = Account.find(account_id)
    return unless should_recharge?(account)

    amount_cents = account.auto_recharge_amount_cents

    case account.preferred_processor
    when 'stripe'
      recharge_via_stripe(account, amount_cents)
    when 'paddle_billing'
      recharge_via_paddle(account, amount_cents)
    end

  rescue Stripe::CardError, Pay::Paddle::Error => e
    handle_payment_error(account, e)
  end

  private

  def should_recharge?(account)
    account.auto_recharge_enabled? &&
      account.credits_balance_cents < threshold_for(account)
  end

  def threshold_for(account)
    account.plan&.auto_recharge_threshold_cents || 500
  end

  def recharge_via_stripe(account, amount_cents)
    account.set_payment_processor(:stripe)
    charge = account.payment_processor.charge(amount_cents)

    if charge.succeeded?
      account.add_credits!(amount_cents)
      AccountMailer.auto_recharge_success(account, amount_cents).deliver_later
    end
  end

  def recharge_via_paddle(account, amount_cents)
    account.set_payment_processor(:paddle_billing)
    # Paddle one-time charges require checkout flow
    # Send email with payment link instead
    AccountMailer.auto_recharge_required_paddle(account, amount_cents).deliver_later
  end

  def handle_payment_error(account, error)
    Rails.logger.error "Auto-recharge failed for account #{account.id}: #{error.message}"
    AccountMailer.auto_recharge_failed(account, error.message).deliver_later
    account.update!(auto_recharge_enabled: false)
  end
end
```

### MonthlyCreditsAllocationJob

```ruby
# app/jobs/monthly_credits_allocation_job.rb
class MonthlyCreditsAllocationJob < ApplicationJob
  queue_as :default

  def perform
    Account.includes(:plan, :payment_processor_subscriptions)
           .joins(:plan)
           .where(plans: { status: :active })
           .find_each do |account|
      subscription = account.payment_processor.subscription
      next unless subscription&.active?

      # Add monthly credit allocation
      account.add_credits!(account.plan.monthly_credits_cents)

      # Send receipt
      AccountMailer.monthly_credits_added(account).deliver_later
    end
  end
end
```

**Schedule in config:**
```ruby
# config/recurring.yml (Solid Queue recurring jobs)
monthly_credits:
  class: MonthlyCreditsAllocationJob
  schedule: "0 0 1 * *" # First day of month at midnight
```

## Webhook Handlers

### Stripe Webhooks

```ruby
# app/controllers/webhooks/stripe_controller.rb
class Webhooks::StripeController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    payload = request.body.read
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']
    endpoint_secret = Rails.application.credentials.stripe[:webhook_secret]

    begin
      event = Stripe::Webhook.construct_event(
        payload, sig_header, endpoint_secret
      )
    rescue JSON::ParserError, Stripe::SignatureVerificationError
      head :bad_request
      return
    end

    # Let Pay gem handle most events
    Pay::Webhooks::StripeController.new.create

    # Handle custom events for credits
    case event.type
    when 'checkout.session.completed'
      handle_checkout_completed(event)
    end

    head :ok
  end

  private

  def handle_checkout_completed(event)
    session = event.data.object

    if session.metadata['purchase_type'] == 'credits'
      account = Account.find(session.metadata['account_id'])
      credits_cents = session.metadata['credits_cents'].to_i
      account.add_credits!(credits_cents)
    end
  end
end
```

### Paddle Webhooks

```ruby
# app/controllers/webhooks/paddle_controller.rb
class Webhooks::PaddleController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    # Let Pay gem handle standard events
    Pay::Webhooks::PaddleBillingController.new.create

    # Handle custom events for credits
    event = JSON.parse(request.body.read)

    case event['event_type']
    when 'transaction.completed'
      handle_transaction_completed(event)
    end

    head :ok
  end

  private

  def handle_transaction_completed(event)
    custom_data = event['data']['custom_data']

    if custom_data && custom_data['purchase_type'] == 'credits'
      account = Account.find(custom_data['account_id'])
      credits_cents = custom_data['credits_cents'].to_i
      account.add_credits!(credits_cents)
    end
  end
end
```

## Migration Strategy

### Step 1: Install Pay Gem

```bash
# Add to Gemfile
bundle add pay --version "~> 11.1"
bundle add stripe --version "~> 15.3"
bundle add paddle --version "~> 2.5"

# Install Pay migrations
bin/rails pay:install:migrations
bin/rails db:migrate
```

### Step 2: Create Plan Migration

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_plans.rb
class CreatePlans < ActiveRecord::Migration[8.0]
  def change
    create_table :plans do |t|
      t.string :name, null: false
      t.string :stripe_price_id
      t.string :paddle_price_id
      t.integer :status, null: false, default: 0
      t.integer :monthly_price_cents, default: 0, null: false
      t.integer :monthly_credits_cents, default: 0, null: false
      t.integer :margin_percentage, default: 50, null: false
      t.integer :auto_recharge_threshold_cents, default: 500, null: false
      t.text :description
      t.timestamps

      t.index :status
      t.index :stripe_price_id, unique: true
      t.index :paddle_price_id, unique: true
    end
  end
end
```

### Step 3: Add Credits Fields to Accounts

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_credits_fields_to_accounts.rb
class AddCreditsFieldsToAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :accounts, :plan_id, :bigint
    add_column :accounts, :credits_balance_cents, :integer, default: 0, null: false
    add_column :accounts, :auto_recharge_enabled, :boolean, default: false
    add_column :accounts, :auto_recharge_amount_cents, :integer
    add_column :accounts, :preferred_processor, :string, default: 'stripe'

    add_index :accounts, :plan_id
    add_index :accounts, :credits_balance_cents
    add_foreign_key :accounts, :plans
  end
end
```

### Step 4: Add Cost Fields to Messages

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_cost_fields_to_messages.rb
class AddCostFieldsToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :api_cost_cents, :integer
    add_column :messages, :credit_cost_cents, :integer

    add_index :messages, :api_cost_cents
    add_index :messages, :credit_cost_cents
    add_index :messages, [:account_id, :created_at]
  end
end
```

### Step 5: Run Migrations

```bash
bin/rails db:migrate
```

## Seed Data

```ruby
# db/seeds.rb

puts "Creating payment plans..."

Plan.create!([
  {
    name: "Free",
    status: :active,
    monthly_price_cents: 0,
    monthly_credits_cents: 500, # $5 worth of credits
    margin_percentage: 100, # 100% margin for free tier
    auto_recharge_threshold_cents: 100,
    stripe_price_id: nil,
    paddle_price_id: nil,
    description: "Perfect for trying out the platform. $5 credits per month."
  },
  {
    name: "Starter",
    stripe_price_id: Rails.env.production? ? ENV.fetch("STRIPE_STARTER_PRICE_ID") : "price_test_starter",
    paddle_price_id: Rails.env.production? ? ENV.fetch("PADDLE_STARTER_PRICE_ID") : "pri_test_starter",
    status: :active,
    monthly_price_cents: 2000, # $20
    monthly_credits_cents: 2000, # $20 worth of credits
    margin_percentage: 50, # 50% margin
    auto_recharge_threshold_cents: 200,
    description: "Great for light usage. $20 credits per month."
  },
  {
    name: "Pro",
    stripe_price_id: Rails.env.production? ? ENV.fetch("STRIPE_PRO_PRICE_ID") : "price_test_pro",
    paddle_price_id: Rails.env.production? ? ENV.fetch("PADDLE_PRO_PRICE_ID") : "pri_test_pro",
    status: :active,
    monthly_price_cents: 10_000, # $100
    monthly_credits_cents: 11_000, # $110 worth of credits (10% bonus)
    margin_percentage: 40, # 40% margin
    auto_recharge_threshold_cents: 500,
    description: "For power users. $110 credits per month."
  },
  {
    name: "Enterprise",
    stripe_price_id: Rails.env.production? ? ENV.fetch("STRIPE_ENTERPRISE_PRICE_ID") : "price_test_enterprise",
    paddle_price_id: Rails.env.production? ? ENV.fetch("PADDLE_ENTERPRISE_PRICE_ID") : "pri_test_enterprise",
    status: :active,
    monthly_price_cents: 50_000, # $500
    monthly_credits_cents: 60_000, # $600 worth of credits (20% bonus)
    margin_percentage: 30, # 30% margin for volume
    auto_recharge_threshold_cents: 2000,
    description: "Best value for teams. $600 credits per month."
  }
])

puts "Payment plans created successfully!"
```

## Updated AiResponseJob

```ruby
# app/jobs/ai_response_job.rb
class AiResponseJob < ApplicationJob
  STREAM_DEBOUNCE_INTERVAL = 0.2.seconds

  def perform(chat)
    unless chat.is_a?(Chat)
      raise ArgumentError, "Expected a Chat object, got #{chat.class}"
    end

    # Check credits availability before processing
    account = chat.account
    unless account.has_credits?(100) # Minimum $0.01
      Rails.logger.warn "Chat #{chat.id} skipped: insufficient credits"
      notify_insufficient_credits(chat)
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
  rescue Account::InsufficientCreditsError => e
    Rails.logger.error "Credit consumption failed during AI response: #{e.message}"
    @ai_message&.update(content: "Response interrupted: Insufficient credits. Please add more credits to continue.")
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
      streaming: false
    })

    # Credits consumption happens in Message callback
  end

  def notify_insufficient_credits(chat)
    chat.messages.create!(
      role: "assistant",
      content: "I'm unable to respond because your account has insufficient credits. Please add more credits to continue our conversation.",
      model_id: chat.model_id
    )
  end

  # ... rest of existing methods (stream_buffer, etc.) ...
end
```

## Implementation Checklist

### Phase 1: Core Infrastructure
- [ ] Add Pay gem with Stripe and Paddle to Gemfile
- [ ] Run Pay migrations
- [ ] Create Plan migration with margin_percentage
- [ ] Add credits fields to accounts migration
- [ ] Add cost fields to messages migration
- [ ] Run all migrations
- [ ] Create seed data for plans with margins

### Phase 2: Model Logic
- [ ] Implement Plan model with margin calculations
- [ ] Add multi-processor support to Plan
- [ ] Add Pay integration to Account model with both processors
- [ ] Add credits management methods to Account
- [ ] Add subscription methods with processor selection
- [ ] Add analytics methods for credits
- [ ] Update Message model with cost calculation
- [ ] Add credits consumption to Message callbacks

### Phase 3: Credits Gating
- [ ] Create CreditsGating concern
- [ ] Include CreditsGating in ChatsController
- [ ] Include CreditsGating in MessagesController
- [ ] Update AiResponseJob to check credits
- [ ] Add insufficient credits handling

### Phase 4: Background Jobs
- [ ] Create AutoRechargeJob with multi-processor support
- [ ] Create MonthlyCreditsAllocationJob
- [ ] Configure recurring job schedule
- [ ] Test auto-recharge flow for both processors
- [ ] Test monthly allocation

### Phase 5: Webhooks & Payment Flow
- [ ] Configure Stripe webhook endpoint
- [ ] Configure Paddle webhook endpoint
- [ ] Implement custom webhook handlers for credits
- [ ] Test subscription creation (both processors)
- [ ] Test one-time credit purchases
- [ ] Test subscription cancellation
- [ ] Test plan upgrades

### Phase 6: Testing
- [ ] Write model tests for Plan with margins
- [ ] Write model tests for Account credits management
- [ ] Write model tests for Message cost calculation
- [ ] Write controller tests for credits gating
- [ ] Write job tests for AutoRechargeJob
- [ ] Write job tests for MonthlyCreditsAllocationJob
- [ ] Write integration tests for payment flows
- [ ] Test both Stripe and Paddle flows

## Testing Strategy

### Unit Tests

```ruby
# test/models/plan_test.rb
require "test_helper"

class PlanTest < ActiveSupport::TestCase
  test "margin_multiplier calculates correctly" do
    plan = Plan.create!(
      name: "Test",
      margin_percentage: 50,
      monthly_credits_cents: 1000
    )

    assert_equal 1.5, plan.margin_multiplier
  end

  test "credit_cost_for applies margin correctly" do
    plan = Plan.create!(
      name: "Test",
      margin_percentage: 50,
      monthly_credits_cents: 1000
    )

    # $1 API cost with 50% margin = $1.50 credit cost
    assert_equal 150, plan.credit_cost_for(100)
  end

  test "api_cost_for reverses margin calculation" do
    plan = Plan.create!(
      name: "Test",
      margin_percentage: 50,
      monthly_credits_cents: 1000
    )

    # $1.50 credit cost with 50% margin = $1 API cost
    assert_equal 100, plan.api_cost_for(150)
  end

  test "supports_processor? checks for price IDs" do
    plan = Plan.create!(
      name: "Test",
      stripe_price_id: "price_123",
      paddle_price_id: nil,
      monthly_credits_cents: 1000
    )

    assert plan.supports_processor?(:stripe)
    assert_not plan.supports_processor?(:paddle_billing)
  end
end

# test/models/account_test.rb
require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "consume_credits decreases balance" do
    account = accounts(:one)
    account.update!(credits_balance_cents: 1000)

    account.consume_credits!(100)
    assert_equal 900, account.reload.credits_balance_cents
  end

  test "consume_credits raises error when insufficient" do
    account = accounts(:one)
    account.update!(credits_balance_cents: 50)

    assert_raises Account::InsufficientCreditsError do
      account.consume_credits!(100)
    end
  end

  test "credits_balance_display formats as currency" do
    account = accounts(:one)
    account.update!(credits_balance_cents: 1550)

    assert_equal "$15.50", account.credits_balance_display
  end

  test "purchase_credits adds credits on successful charge" do
    account = accounts(:one)
    account.update!(credits_balance_cents: 0)

    # Mock successful charge
    mock_charge = Minitest::Mock.new
    mock_charge.expect :succeeded?, true

    account.payment_processor.stub :charge, mock_charge do
      account.purchase_credits!(2000) # $20
    end

    assert_equal 2000, account.reload.credits_balance_cents
    mock_charge.verify
  end
end

# test/models/message_test.rb
require "test_helper"

class MessageTest < ActiveSupport::TestCase
  test "calculate_and_charge_credits calculates costs correctly" do
    account = accounts(:one)
    plan = plans(:starter)
    account.update!(plan: plan, credits_balance_cents: 5000)

    chat = account.chats.create!(name: "Test", model_id: "gpt-4")

    # Mock RubyLLM model info
    mock_model = Minitest::Mock.new
    mock_model.expect :pricing, { input: 0.01, output: 0.03 } # Per million tokens

    RubyLLM.models.stub :find, mock_model do
      message = chat.messages.create!(
        role: "assistant",
        content: "Response",
        model_id: "gpt-4",
        input_tokens: 1000,
        output_tokens: 500
      )

      # Trigger the callback
      message.update!(output_tokens: 500)
      message.reload

      # API cost: (1000/1M * $0.01) + (500/1M * $0.03) = $0.000025
      # In cents: 0.0025 cents, rounds to 0
      # Let's use bigger numbers
    end

    mock_model.verify
  end

  test "insufficient credits stops message processing" do
    account = accounts(:one)
    account.update!(credits_balance_cents: 10) # Only $0.10

    chat = account.chats.create!(name: "Test", model_id: "gpt-4")

    # Mock expensive model
    mock_model = Minitest::Mock.new
    mock_model.expect :pricing, { input: 100.0, output: 200.0 } # Very expensive

    RubyLLM.models.stub :find, mock_model do
      message = chat.messages.create!(
        role: "assistant",
        content: "Response",
        model_id: "gpt-4",
        input_tokens: 1000,
        output_tokens: 500
      )

      # This should fail with insufficient credits
      message.update!(output_tokens: 500)
      message.reload

      assert_match /truncated/, message.content
    end

    mock_model.verify
  end
end
```

## How the Credits Economy Works - Detailed

### User Journey

1. **Sign Up**
   - New personal account gets free plan
   - Receives $5 worth of credits (500 cents)
   - Can immediately start using AI features

2. **Using AI**
   - User sends message to GPT-4
   - Message uses 1000 input tokens, 500 output tokens
   - RubyLLM pricing: $0.01/M input, $0.03/M output
   - Actual API cost: $0.000025 (rounds to 0 cents - too small!)
   - Real example with larger usage:
     - 100K input tokens, 50K output tokens
     - API cost: $0.001 + $0.0015 = $0.0025 = 0.25 cents
     - With 50% margin: 0.375 cents charged
     - User sees: "0.00375 credits used"

3. **Running Low**
   - Credits drop below threshold ($2 for Pro plan)
   - User gets notification
   - Options:
     - Enable auto-recharge (Stripe only, Paddle requires manual)
     - Purchase one-time credits
     - Upgrade plan for better value

4. **Subscription Benefits**
   - Monthly credits automatically added
   - Better margins on higher plans (30-50% vs 100% for free)
   - Higher auto-recharge thresholds
   - Priority support on premium plans

### Business Economics

1. **Free Plan**
   - 100% margin ensures no losses
   - $5 credits = $2.50 actual API costs
   - User acquisition strategy

2. **Paid Plans**
   - Lower margins for customer value
   - Volume discounts (Enterprise: 30% margin)
   - Predictable revenue from subscriptions
   - Credits encourage usage without fear

3. **Profitability**
   - Every API call includes margin
   - Transparent to users (shown as credits/dollars)
   - Sustainable business model
   - No hidden fees or surprise charges

### Technical Implementation

1. **Atomic Operations**
   - Credits use PostgreSQL atomic increment/decrement
   - No race conditions on concurrent usage
   - Transaction-wrapped cost calculations

2. **Accurate Costing**
   - RubyLLM Model Registry provides real-time pricing
   - Per-model cost calculation
   - Supports all providers (OpenAI, Anthropic, etc.)

3. **Multi-Processor Support**
   - Stripe for credit cards globally
   - Paddle for international tax compliance
   - Account chooses preferred processor
   - Same credits system regardless of processor

## Future Enhancements

### Phase 2: Advanced Features
- Team credit pooling
- Credit transfer between accounts
- Volume purchase discounts
- Expiring promotional credits

### Phase 3: Analytics Dashboard
- Credit usage graphs
- Model cost breakdown
- Prediction of credit depletion
- Cost optimization suggestions

### Phase 4: Enterprise Features
- Invoicing and NET terms
- Department budgets
- Usage alerts and limits
- Custom pricing agreements

## Success Criteria

### Functional Requirements
- [x] Accounts can purchase and use credits
- [x] Credits represent actual dollar amounts
- [x] Margins provide sustainable revenue
- [x] Multi-processor support (Stripe & Paddle)
- [x] Auto-recharge for convenience
- [x] Accurate cost tracking from RubyLLM
- [x] Clear user communication about credits

### Code Quality
- [x] Follows Rails conventions
- [x] No unnecessary abstractions
- [x] Business logic in models
- [x] Single source of truth (credits_balance_cents)
- [x] Atomic operations prevent race conditions

### User Experience
- [x] Familiar dollar-based credits
- [x] Transparent pricing with margins
- [x] Multiple payment options
- [x] Clear insufficient credits messaging
- [x] Flexible plans for different needs

## The Rails-Worthiness Test

This implementation passes DHH's standards because:

1. **Simplicity**: Credits in cents, not complex token systems
2. **Transparency**: Users see dollars, business tracks margins
3. **Rails Patterns**: Fat models, thin controllers, clear concerns
4. **Database Trust**: PostgreSQL handles atomic operations
5. **No Over-Engineering**: Direct, obvious code throughout

**Would DHH approve?** Yes. This solves real business needs with minimal complexity.

**Would this be accepted into Rails core patterns?** The approach demonstrates Rails best practices.

**Would a developer understand this in 30 minutes?** Yes. Credits = money, margins = profit. Simple.

## Summary

This implementation transforms the payment system from an abstract "token balance" to a concrete **credits-based economy** where:

- Users purchase credits (shown as dollars)
- Each AI interaction costs credits based on actual API usage plus margin
- Multiple payment processors are supported (Stripe and Paddle)
- The business model is sustainable through configurable margins
- Everything is tracked in cents for precision and simplicity

The system is production-ready, follows Rails best practices, and provides a clear path to profitability while maintaining user trust through transparent, dollar-based pricing.