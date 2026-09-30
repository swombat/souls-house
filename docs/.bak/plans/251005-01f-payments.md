# Payments System Implementation Plan (Corrected Version)

## Executive Summary

A clean, Rails-worthy payments system that supports flexible billing for AI API usage. Users maintain a **prepaid balance in dollars** that gets consumed by AI interactions. The system supports both subscription and pay-as-you-go (PAYG) plans through Stripe and Paddle Billing, tracks actual API costs using RubyLLM's Model Registry for analytics, and enables sustainable pricing through direct message cost calculation.

**Key architectural principles:**
- No "credits" abstraction - just dollars in the account balance
- Messages calculate their own cost using RubyLLM Model Registry
- Plans only define subscription tiers and PAYG options, NOT per-message pricing
- Leverage Pay gem's built-in balance tracking
- Separate user billing from internal cost analytics

## Architecture Overview

### Core Philosophy

**Delete code. Trust Rails. Use the framework.**

- **One currency** - Dollars stored as cents, no fake "credits"
- **Pay gem does the work** - Use its balance tracking, don't reinvent
- **Message-based pricing** - Messages know their own cost via RubyLLM
- **Two plan types** - Subscriptions (recurring) and PAYG (one-time)
- **Separate concerns** - User billing vs. internal analytics

### Key Concepts

1. **Account Balance** - Users prepay into their account (like a Starbucks card)
2. **Subscription Plans** - Monthly price with included balance allocation
3. **PAYG Plans** - One-time purchases to add balance
4. **Message Cost** - Calculated directly from RubyLLM Model Registry pricing
5. **Auto-recharge** - Automatically purchase a PAYG plan when balance is low
6. **Cost Analytics** - Track actual vs. billed amounts for profitability

## Database Schema

### New Tables

#### plans
```ruby
create_table :plans do |t|
  t.string :name, null: false
  t.string :plan_type, null: false  # 'subscription' or 'payg'

  # Payment processor IDs
  t.string :stripe_price_id
  t.string :paddle_price_id

  # Common fields
  t.integer :status, null: false, default: 0  # active, archived
  t.integer :sort_order, default: 0

  # Subscription plan fields
  t.integer :monthly_price_cents  # Monthly subscription cost
  t.integer :monthly_allocation_cents  # Balance added each month

  # PAYG plan fields
  t.integer :amount_cents  # One-time payment amount
  t.integer :credits_cents  # Balance to add (usually same as amount_cents)

  t.timestamps

  t.index :status
  t.index :plan_type
  t.index :stripe_price_id, unique: true
  t.index :paddle_price_id, unique: true
end
```

### Schema Modifications

#### accounts
```ruby
add_column :accounts, :plan_id, :bigint  # Current subscription plan
add_column :accounts, :balance_cents, :integer, default: 0, null: false
add_column :accounts, :auto_recharge_enabled, :boolean, default: false
add_column :accounts, :auto_recharge_plan_id, :bigint  # PAYG plan to purchase
add_column :accounts, :auto_recharge_threshold_cents, :integer, default: 500

add_index :accounts, :plan_id
add_index :accounts, :auto_recharge_plan_id
add_foreign_key :accounts, :plans
add_foreign_key :accounts, :plans, column: :auto_recharge_plan_id
```

#### messages
```ruby
add_column :messages, :cost_cents, :integer  # What the message actually cost
add_index :messages, [:account_id, :created_at]
```

## Model Implementation

### Plan Model

```ruby
# app/models/plan.rb
class Plan < ApplicationRecord
  has_many :accounts
  has_many :auto_recharge_accounts, class_name: 'Account',
           foreign_key: 'auto_recharge_plan_id'

  enum :status, { active: 0, archived: 1 }
  enum :plan_type, { subscription: 0, payg: 1 }

  validates :name, presence: true, uniqueness: true
  validates :plan_type, presence: true

  # Subscription plan validations
  validates :monthly_price_cents, presence: true,
            numericality: { greater_than_or_equal_to: 0 },
            if: :subscription?
  validates :monthly_allocation_cents, presence: true,
            numericality: { greater_than_or_equal_to: 0 },
            if: :subscription?

  # PAYG plan validations
  validates :amount_cents, presence: true,
            numericality: { greater_than: 0 },
            if: :payg?
  validates :credits_cents, presence: true,
            numericality: { greater_than: 0 },
            if: :payg?

  scope :available, -> { active.order(:sort_order, :name) }
  scope :subscriptions, -> { subscription.available }
  scope :payg_options, -> { payg.available }

  def free?
    subscription? && monthly_price_cents.zero?
  end

  def formatted_price
    if subscription?
      "$#{monthly_price_cents / 100.0}/month"
    else
      "$#{amount_cents / 100.0}"
    end
  end

  def formatted_credits
    if subscription?
      "$#{monthly_allocation_cents / 100.0} monthly"
    else
      "$#{credits_cents / 100.0}"
    end
  end
end
```

### Account Model Extensions

```ruby
# app/models/account.rb
class Account < ApplicationRecord
  pay_customer stripe_attributes: :stripe_attributes,
               paddle_attributes: :paddle_attributes

  belongs_to :plan, optional: true  # Current subscription
  belongs_to :auto_recharge_plan, class_name: 'Plan', optional: true

  after_create :setup_free_plan

  # Balance management via Pay gem
  def has_sufficient_balance?(amount_cents = 1)
    payment_processor.balance >= amount_cents
  end

  def charge_for_usage!(amount_cents, description:)
    raise InsufficientFundsError unless has_sufficient_balance?(amount_cents)

    payment_processor.decrement_balance!(amount_cents, description: description)
    trigger_auto_recharge if should_auto_recharge?
  rescue Pay::Error => e
    raise InsufficientFundsError, e.message
  end

  def add_funds!(amount_cents, description: "Added funds")
    payment_processor.increment_balance!(amount_cents, description: description)
  end

  def balance
    payment_processor.balance
  end

  def formatted_balance
    "$%.2f" % (balance / 100.0)
  end

  # Subscription management
  def subscribe_to_plan!(plan)
    raise ArgumentError, "Plan must be a subscription" unless plan.subscription?
    raise ArgumentError, "Plan must be active" unless plan.active?

    price_id = stripe? ? plan.stripe_price_id : plan.paddle_price_id
    payment_processor.subscribe(name: "default", plan: price_id)
    update!(plan: plan)
  end

  def cancel_subscription!
    payment_processor.subscription.cancel
    update!(plan: nil)
  end

  # PAYG purchase
  def purchase_credits!(plan)
    raise ArgumentError, "Plan must be PAYG" unless plan.payg?
    raise ArgumentError, "Plan must be active" unless plan.active?

    price_id = stripe? ? plan.stripe_price_id : plan.paddle_price_id
    charge = payment_processor.charge(plan.amount_cents,
                                     price_id: price_id,
                                     description: "Purchase #{plan.name}")

    if charge.succeeded?
      add_funds!(plan.credits_cents, description: "Purchased #{plan.name}")
    else
      raise PaymentFailedError, "Payment failed: #{charge.error_message}"
    end
  end

  # Usage tracking (for analytics only)
  def api_costs_this_month
    messages.assistant
            .where(created_at: Time.current.all_month)
            .sum(:cost_cents)
  end

  def usage_this_month
    api_costs_this_month  # Direct cost, no markup
  end

  def messages_this_month
    messages.assistant
            .where(created_at: Time.current.all_month)
            .count
  end

  private

  def setup_free_plan
    free_plan = Plan.find_by(plan_type: :subscription, monthly_price_cents: 0)
    return unless free_plan

    update!(plan: free_plan)
    add_funds!(free_plan.monthly_allocation_cents, description: "Welcome bonus")
  end

  def should_auto_recharge?
    auto_recharge_enabled? &&
      auto_recharge_plan.present? &&
      balance < auto_recharge_threshold_cents
  end

  def trigger_auto_recharge
    AutoRechargeJob.perform_later(self)
  end

  def stripe?
    payment_processor.processor == 'stripe'
  end

  def stripe_attributes
    { metadata: { account_id: id } }
  end

  def paddle_attributes
    { custom_data: { account_id: id } }
  end

  class InsufficientFundsError < StandardError; end
  class PaymentFailedError < StandardError; end
end
```

### Message Model Extensions

```ruby
# app/models/message.rb
class Message < ApplicationRecord
  belongs_to :chat
  has_one :account, through: :chat

  # RubyLLM automatically populates input_tokens, output_tokens via acts_as_message
  acts_as_message

  after_commit :calculate_and_charge, on: :update,
               if: -> { saved_change_to_output_tokens? && assistant? }

  private

  def calculate_and_charge
    return unless output_tokens.present? && model_id.present?

    # Calculate actual cost using RubyLLM Model Registry
    cost = calculate_cost_from_model_registry

    # Store the cost for analytics
    update_column(:cost_cents, cost)

    # Charge the account
    account.charge_for_usage!(cost, description: "AI message (#{model_id})")

  rescue Account::InsufficientFundsError
    handle_insufficient_funds
  end

  def calculate_cost_from_model_registry
    # Get model pricing from RubyLLM Model Registry
    model = RubyLLM.models.find(model_id)
    return 0 unless model&.input_price_per_million && model&.output_price_per_million

    # Calculate cost in cents
    # Prices are per million tokens, we have actual token counts
    input_cost = (input_tokens.to_f / 1_000_000) * model.input_price_per_million * 100
    output_cost = (output_tokens.to_f / 1_000_000) * model.output_price_per_million * 100

    (input_cost + output_cost).round
  end

  def handle_insufficient_funds
    Rails.logger.error "Insufficient funds for message #{id}"
    # Optionally truncate or mark the message
    update_column(:content, content.to_s + "\n\n[Response limited: Insufficient balance]")

    # Notify user via ActionCable
    broadcast_marker(
      "Chat:#{chat.to_param}",
      {
        action: "insufficient_funds",
        message: "Please add funds to continue"
      }
    )
  end
end
```

## Controller Concern: BalanceGating

```ruby
# app/controllers/concerns/balance_gating.rb
module BalanceGating
  extend ActiveSupport::Concern

  included do
    before_action :require_balance, only: [:create]
  end

  private

  def require_balance
    # Check for minimum balance (1 cent as absolute minimum)
    # Real cost will be calculated after message completion
    return if current_account.has_sufficient_balance?(1)

    redirect_back_or_to account_billing_path(current_account),
                        alert: "Insufficient balance. Please add funds to continue.",
                        inertia: {
                          errors: {
                            balance: "Insufficient funds",
                            current_balance: current_account.formatted_balance
                          }
                        }
  end
end
```

## Background Jobs

### AutoRechargeJob

```ruby
# app/jobs/auto_recharge_job.rb
class AutoRechargeJob < ApplicationJob
  def perform(account)
    return unless account.auto_recharge_enabled?
    return unless account.auto_recharge_plan&.active?
    return if account.balance >= account.auto_recharge_threshold_cents

    # Purchase the configured PAYG plan
    account.purchase_credits!(account.auto_recharge_plan)

    AccountMailer.auto_recharge_success(account).deliver_later
  rescue Account::PaymentFailedError => e
    account.update!(auto_recharge_enabled: false)
    AccountMailer.auto_recharge_failed(account, e.message).deliver_later
  end
end
```

### MonthlyAllocationJob

```ruby
# app/jobs/monthly_allocation_job.rb
class MonthlyAllocationJob < ApplicationJob
  def perform
    Account.joins(:plan)
           .where(plans: { plan_type: :subscription })
           .where.not(plans: { monthly_allocation_cents: 0 })
           .find_each do |account|
      next unless account.payment_processor.subscribed?

      account.add_funds!(
        account.plan.monthly_allocation_cents,
        description: "Monthly allocation - #{account.plan.name}"
      )
    end
  end
end
```

## Webhook Handlers

```ruby
# app/controllers/webhooks_controller.rb
class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def stripe
    # Let Pay gem handle everything
    Pay::Webhooks::StripeController.new.create
    head :ok
  end

  def paddle
    # Let Pay gem handle everything
    Pay::Webhooks::PaddleBillingController.new.create
    head :ok
  end
end
```

## Migration Strategy

### Step 1: Install Pay Gem
```bash
bundle add pay --version "~> 11.1"
bundle add stripe
bundle add paddle
bin/rails pay:install:migrations
```

### Step 2: Create Migrations
```ruby
# db/migrate/xxx_create_plans.rb
class CreatePlans < ActiveRecord::Migration[8.0]
  def change
    create_table :plans do |t|
      t.string :name, null: false
      t.string :plan_type, null: false
      t.string :stripe_price_id
      t.string :paddle_price_id
      t.integer :status, null: false, default: 0
      t.integer :sort_order, default: 0

      # Subscription fields
      t.integer :monthly_price_cents
      t.integer :monthly_allocation_cents

      # PAYG fields
      t.integer :amount_cents
      t.integer :credits_cents

      t.timestamps

      t.index :status
      t.index :plan_type
      t.index :stripe_price_id, unique: true
      t.index :paddle_price_id, unique: true
    end
  end
end

# db/migrate/xxx_add_billing_to_accounts.rb
class AddBillingToAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :accounts, :plan_id, :bigint
    add_column :accounts, :balance_cents, :integer, default: 0, null: false
    add_column :accounts, :auto_recharge_enabled, :boolean, default: false
    add_column :accounts, :auto_recharge_plan_id, :bigint
    add_column :accounts, :auto_recharge_threshold_cents, :integer, default: 500

    add_index :accounts, :plan_id
    add_index :accounts, :auto_recharge_plan_id
    add_foreign_key :accounts, :plans
    add_foreign_key :accounts, :plans, column: :auto_recharge_plan_id
  end
end

# db/migrate/xxx_add_cost_to_messages.rb
class AddCostToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :cost_cents, :integer
    add_index :messages, [:account_id, :created_at]
  end
end
```

### Step 3: Seed Data
```ruby
# db/seeds.rb

# Subscription plans
Plan.create!([
  {
    name: "Free",
    plan_type: :subscription,
    status: :active,
    monthly_price_cents: 0,
    monthly_allocation_cents: 500,  # $5 free
    sort_order: 1
  },
  {
    name: "Starter",
    plan_type: :subscription,
    stripe_price_id: ENV["STRIPE_STARTER_PRICE"],
    paddle_price_id: ENV["PADDLE_STARTER_PRICE"],
    status: :active,
    monthly_price_cents: 2000,  # $20/month
    monthly_allocation_cents: 2000,  # $20 balance included
    sort_order: 2
  },
  {
    name: "Pro",
    plan_type: :subscription,
    stripe_price_id: ENV["STRIPE_PRO_PRICE"],
    paddle_price_id: ENV["PADDLE_PRO_PRICE"],
    status: :active,
    monthly_price_cents: 5000,  # $50/month
    monthly_allocation_cents: 5000,  # $50 balance included
    sort_order: 3
  },
  {
    name: "Business",
    plan_type: :subscription,
    stripe_price_id: ENV["STRIPE_BUSINESS_PRICE"],
    paddle_price_id: ENV["PADDLE_BUSINESS_PRICE"],
    status: :active,
    monthly_price_cents: 10000,  # $100/month
    monthly_allocation_cents: 12000,  # $120 balance included (20% bonus)
    sort_order: 4
  }
])

# PAYG plans
Plan.create!([
  {
    name: "Add $5",
    plan_type: :payg,
    stripe_price_id: ENV["STRIPE_PAYG_5_PRICE"],
    paddle_price_id: ENV["PADDLE_PAYG_5_PRICE"],
    status: :active,
    amount_cents: 500,
    credits_cents: 500,
    sort_order: 10
  },
  {
    name: "Add $10",
    plan_type: :payg,
    stripe_price_id: ENV["STRIPE_PAYG_10_PRICE"],
    paddle_price_id: ENV["PADDLE_PAYG_10_PRICE"],
    status: :active,
    amount_cents: 1000,
    credits_cents: 1000,
    sort_order: 11
  },
  {
    name: "Add $25",
    plan_type: :payg,
    stripe_price_id: ENV["STRIPE_PAYG_25_PRICE"],
    paddle_price_id: ENV["PADDLE_PAYG_25_PRICE"],
    status: :active,
    amount_cents: 2500,
    credits_cents: 2500,
    sort_order: 12
  },
  {
    name: "Add $50",
    plan_type: :payg,
    stripe_price_id: ENV["STRIPE_PAYG_50_PRICE"],
    paddle_price_id: ENV["PADDLE_PAYG_50_PRICE"],
    status: :active,
    amount_cents: 5000,
    credits_cents: 5000,
    sort_order: 13
  },
  {
    name: "Add $100",
    plan_type: :payg,
    stripe_price_id: ENV["STRIPE_PAYG_100_PRICE"],
    paddle_price_id: ENV["PADDLE_PAYG_100_PRICE"],
    status: :active,
    amount_cents: 10000,
    credits_cents: 10000,
    sort_order: 14
  }
])
```

## Implementation Checklist

### Phase 1: Core Infrastructure
- [ ] Add Pay gem with Stripe and Paddle support
- [ ] Run Pay migrations
- [ ] Create Plan migration with plan_type field
- [ ] Add balance and auto-recharge fields to accounts
- [ ] Add cost_cents field to messages
- [ ] Run migrations and seed data

### Phase 2: Model Implementation
- [ ] Implement Plan model with subscription/PAYG types
- [ ] Update Account model to use Pay's balance tracking
- [ ] Add subscription and PAYG purchase methods to Account
- [ ] Update Message model to calculate cost from RubyLLM Model Registry
- [ ] Remove any Plan involvement in message pricing

### Phase 3: Usage Control
- [ ] Create BalanceGating concern
- [ ] Include in ChatsController and MessagesController
- [ ] Update AiResponseJob to handle insufficient funds
- [ ] Add ActionCable notifications for balance issues

### Phase 4: Background Jobs
- [ ] Create AutoRechargeJob using PAYG plans
- [ ] Create MonthlyAllocationJob for subscriptions
- [ ] Configure recurring jobs with solid_queue

### Phase 5: Payment Integration
- [ ] Configure webhook endpoints
- [ ] Create Stripe products/prices for all plans
- [ ] Create Paddle products/prices for all plans
- [ ] Test subscription flow
- [ ] Test PAYG purchases
- [ ] Test auto-recharge with PAYG plans

## Testing Strategy

```ruby
# test/models/account_test.rb
class AccountTest < ActiveSupport::TestCase
  test "charge_for_usage decrements balance via Pay" do
    account = accounts(:one)
    account.payment_processor.increment_balance!(1000)  # $10

    account.charge_for_usage!(100, description: "Test")
    assert_equal 900, account.balance
  end

  test "insufficient funds raises error" do
    account = accounts(:one)
    account.payment_processor.update!(balance: 50)

    assert_raises Account::InsufficientFundsError do
      account.charge_for_usage!(100, description: "Test")
    end
  end

  test "purchase_credits adds balance for PAYG plan" do
    account = accounts(:one)
    payg_plan = plans(:add_10)  # $10 PAYG plan

    # Stub successful charge
    account.purchase_credits!(payg_plan)

    assert_equal 1000, account.balance
  end
end

# test/models/message_test.rb
class MessageTest < ActiveSupport::TestCase
  test "assistant message calculates cost from RubyLLM Model Registry" do
    account = accounts(:one)
    account.payment_processor.increment_balance!(1000)

    chat = account.chats.create!(name: "Test")
    message = chat.messages.create!(
      role: "assistant",
      content: "Response",
      model_id: "gpt-4o"
    )

    # Simulate token update from RubyLLM
    # Assuming GPT-4o costs $2.50/$10 per million tokens (input/output)
    message.update!(input_tokens: 1000, output_tokens: 500)

    # Cost should be: (1000/1M * $2.50 + 500/1M * $10) * 100 cents
    # = (0.0025 + 0.005) * 100 = 0.75 cents (rounded to 1 cent)
    assert_equal 1, message.reload.cost_cents
    assert_equal 999, account.reload.balance
  end

  test "handles insufficient funds gracefully" do
    account = accounts(:one)
    account.payment_processor.update!(balance: 0)

    chat = account.chats.create!(name: "Test")
    message = chat.messages.create!(
      role: "assistant",
      content: "Response",
      model_id: "gpt-4o"
    )

    message.update!(input_tokens: 1000, output_tokens: 500)

    assert_match /Insufficient balance/, message.reload.content
  end
end

# test/models/plan_test.rb
class PlanTest < ActiveSupport::TestCase
  test "subscription plans have monthly fields" do
    plan = Plan.create!(
      name: "Test Sub",
      plan_type: :subscription,
      monthly_price_cents: 2000,
      monthly_allocation_cents: 2500
    )

    assert plan.subscription?
    assert_equal "$20.0/month", plan.formatted_price
    assert_equal "$25.0 monthly", plan.formatted_credits
  end

  test "PAYG plans have amount and credits fields" do
    plan = Plan.create!(
      name: "Test PAYG",
      plan_type: :payg,
      amount_cents: 1000,
      credits_cents: 1000
    )

    assert plan.payg?
    assert_equal "$10.0", plan.formatted_price
    assert_equal "$10.0", plan.formatted_credits
  end
end
```

## Success Criteria

✅ **Simple**: No credits abstraction, just dollars
✅ **Clear**: Direct message cost calculation from RubyLLM
✅ **Two plan types**: Subscription and PAYG clearly separated
✅ **Leverages Pay**: Uses gem's balance tracking
✅ **Flexible**: Supports subscriptions, PAYG, and auto-recharge
✅ **Multi-processor**: Works with Stripe and Paddle

## The Rails-Worthiness Test

**Would DHH approve?** Yes. This is even simpler and clearer than before.

**Core improvements from user feedback:**
- Removed ALL Plan pricing logic - plans are just payment options
- Messages calculate their own cost using RubyLLM Model Registry
- Clear separation between subscription and PAYG plans
- Auto-recharge uses predefined PAYG plans, not custom amounts
- Direct, transparent pricing with no hidden margins or markups

**The result:** Cleaner architecture, clearer separation of concerns.

## Key Architectural Decisions

### 1. Message-Based Pricing
Messages are responsible for calculating their own cost using the RubyLLM Model Registry. This is the correct separation of concerns:
- Messages know their model and token counts
- RubyLLM Model Registry provides the pricing
- Simple multiplication gives the cost
- No Plan involvement whatsoever

### 2. Two Distinct Plan Types
Plans are purely about payment options, not pricing:
- **Subscription plans**: Recurring monthly charge with balance allocation
- **PAYG plans**: One-time purchase to add specific balance amount
- Both types work through the same balance system
- Users can combine both (subscription + top-ups)

### 3. Auto-Recharge Simplification
Auto-recharge references a specific PAYG plan rather than custom amounts:
- User selects from existing PAYG plans
- When balance is low, automatically purchase that plan
- Simpler implementation and clearer for users
- Reuses existing purchase flow

## Summary

This implementation provides a production-ready payments system that:

1. **Uses dollars throughout** - No confusing abstractions
2. **Message-based costing** - Each message calculates its own cost from RubyLLM
3. **Two plan types** - Clear distinction between subscriptions and PAYG
4. **Leverages Pay gem** - Uses battle-tested payment infrastructure
5. **Supports flexibility** - Mix and match subscriptions with PAYG top-ups

The system is straightforward: users maintain a prepaid balance in dollars, messages cost money based on actual API pricing, and users can fund their account through subscriptions or one-time purchases. Clean, simple, Rails-worthy.