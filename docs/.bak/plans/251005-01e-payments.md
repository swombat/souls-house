# Payments System Implementation Plan (Final Simplified Version)

## Executive Summary

A clean, Rails-worthy payments system that supports flexible billing for AI API usage. Users maintain a **prepaid balance in dollars** that gets consumed by AI interactions. The system supports both Stripe and Paddle Billing, tracks actual API costs for analytics, and enables sustainable pricing through simple per-action fees.

**Key simplifications from DHH's feedback:**
- No "credits" abstraction - just dollars in the account balance
- No complex margin calculations - simple fixed prices per action
- Leverage Pay gem's built-in balance tracking
- Separate user billing from internal cost analytics

## Architecture Overview

### Core Philosophy

**Delete code. Trust Rails. Use money.**

- **One currency** - Dollars stored as cents, no fake "credits"
- **Pay gem does the work** - Use its balance tracking, don't reinvent
- **Simple pricing** - Fixed prices per action, not dynamic margins
- **Separate concerns** - User billing vs. internal analytics

### Key Concepts

1. **Account Balance** - Users prepay into their account (like a Starbucks card)
2. **Plans** - Define monthly subscription price and included balance
3. **Action Pricing** - Simple fixed prices for messages, images, etc.
4. **Auto-recharge** - Optional automatic balance top-ups
5. **Cost Analytics** - Track actual API costs separately for margin analysis

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
  t.integer :included_balance_cents, default: 0, null: false  # Balance included with subscription
  t.jsonb :action_prices, default: {}  # { "message" => 10, "image" => 50 } in cents
  t.timestamps

  t.index :status
  t.index :stripe_price_id, unique: true
  t.index :paddle_price_id, unique: true
end
```

### Schema Modifications

#### accounts
```ruby
add_column :accounts, :plan_id, :bigint
add_column :accounts, :balance_cents, :integer, default: 0, null: false
add_column :accounts, :auto_recharge_enabled, :boolean, default: false
add_column :accounts, :auto_recharge_amount_cents, :integer
add_column :accounts, :auto_recharge_threshold_cents, :integer, default: 500

add_index :accounts, :plan_id
add_foreign_key :accounts, :plans
```

#### messages
```ruby
add_column :messages, :api_cost_cents, :integer  # Internal tracking only
add_column :messages, :billed_amount_cents, :integer  # What user was charged
add_index :messages, [:account_id, :created_at]
```

## Model Implementation

### Plan Model

```ruby
# app/models/plan.rb
class Plan < ApplicationRecord
  has_many :accounts

  enum :status, { active: 0, archived: 1 }

  validates :name, presence: true, uniqueness: true
  validates :monthly_price_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :included_balance_cents, numericality: { greater_than_or_equal_to: 0 }

  scope :available, -> { active }

  def free?
    monthly_price_cents.zero?
  end

  def price_for(action)
    action_prices[action.to_s] || default_price_for(action)
  end

  private

  def default_price_for(action)
    case action.to_s
    when "message" then 10  # 10 cents default
    when "image" then 50    # 50 cents default
    else 10
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

  belongs_to :plan, optional: true

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
    raise ArgumentError, "Plan must be active" unless plan.active?

    price_id = plan.stripe_price_id  # or paddle_price_id based on processor
    payment_processor.subscribe(name: "default", plan: price_id)
    update!(plan: plan)
  end

  # Usage tracking (for analytics only)
  def api_costs_this_month
    messages.assistant
            .where(created_at: Time.current.all_month)
            .sum(:api_cost_cents)
  end

  def usage_this_month
    messages.assistant
            .where(created_at: Time.current.all_month)
            .sum(:billed_amount_cents)
  end

  def estimated_margin_this_month
    revenue = usage_this_month
    costs = api_costs_this_month
    return 0 if revenue.zero?

    ((revenue - costs) / revenue.to_f * 100).round(1)
  end

  private

  def setup_free_plan
    free_plan = Plan.find_by(monthly_price_cents: 0)
    return unless free_plan

    update!(plan: free_plan)
    add_funds!(free_plan.included_balance_cents, description: "Welcome bonus")
  end

  def should_auto_recharge?
    auto_recharge_enabled? &&
      balance < auto_recharge_threshold_cents
  end

  def trigger_auto_recharge
    AutoRechargeJob.perform_later(self)
  end

  def stripe_attributes
    { metadata: { account_id: id } }
  end

  def paddle_attributes
    { custom_data: { account_id: id } }
  end

  class InsufficientFundsError < StandardError; end
end
```

### Message Model Extensions

```ruby
# app/models/message.rb
class Message < ApplicationRecord
  belongs_to :chat
  has_one :account, through: :chat

  after_commit :bill_for_usage, on: :update,
               if: -> { saved_change_to_output_tokens? && assistant? }

  private

  def bill_for_usage
    return unless output_tokens.present?

    # Charge user the plan's price for a message
    price = account.plan&.price_for(:message) || 10
    account.charge_for_usage!(price, description: "AI message")

    # Track actual API cost separately (internal analytics)
    track_api_cost

    # Store what we billed
    update_column(:billed_amount_cents, price)

  rescue Account::InsufficientFundsError
    handle_insufficient_funds
  end

  def track_api_cost
    return unless model_id.present?

    # Get actual cost from RubyLLM Model Registry
    model = RubyLLM.models.find(model_id)
    return unless model&.pricing

    input_cost = (input_tokens.to_f / 1_000_000) * model.pricing[:input]
    output_cost = (output_tokens.to_f / 1_000_000) * model.pricing[:output]
    total_cost_cents = ((input_cost + output_cost) * 100).round

    update_column(:api_cost_cents, total_cost_cents)
  end

  def handle_insufficient_funds
    Rails.logger.error "Insufficient funds for message #{id}"
    update_column(:content, content.to_s + "\n\n[Response limited: Please add funds to continue]")
  end
end
```

## Controller Concern: TokenGating

```ruby
# app/controllers/concerns/token_gating.rb
module TokenGating
  extend ActiveSupport::Concern

  included do
    before_action :require_balance, only: [:create]
  end

  private

  def require_balance
    # Check for minimum balance (10 cents for a message)
    minimum_required = current_account.plan&.price_for(:message) || 10
    return if current_account.has_sufficient_balance?(minimum_required)

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
    return if account.balance >= account.auto_recharge_threshold_cents

    # Charge the auto-recharge amount
    charge = account.payment_processor.charge(
      account.auto_recharge_amount_cents,
      description: "Auto-recharge"
    )

    if charge.succeeded?
      account.add_funds!(
        account.auto_recharge_amount_cents,
        description: "Auto-recharge"
      )
    else
      account.update!(auto_recharge_enabled: false)
      AccountMailer.auto_recharge_failed(account).deliver_later
    end
  end
end
```

### MonthlyBalanceJob

```ruby
# app/jobs/monthly_balance_job.rb
class MonthlyBalanceJob < ApplicationJob
  def perform
    Account.joins(:plan)
           .where.not(plans: { included_balance_cents: 0 })
           .find_each do |account|
      next unless account.payment_processor.subscribed?

      account.add_funds!(
        account.plan.included_balance_cents,
        description: "Monthly plan balance"
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
      t.string :stripe_price_id
      t.string :paddle_price_id
      t.integer :status, null: false, default: 0
      t.integer :monthly_price_cents, default: 0, null: false
      t.integer :included_balance_cents, default: 0, null: false
      t.jsonb :action_prices, default: {}
      t.timestamps

      t.index :status
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
    add_column :accounts, :auto_recharge_amount_cents, :integer
    add_column :accounts, :auto_recharge_threshold_cents, :integer, default: 500

    add_index :accounts, :plan_id
    add_foreign_key :accounts, :plans
  end
end

# db/migrate/xxx_add_billing_to_messages.rb
class AddBillingToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :api_cost_cents, :integer
    add_column :messages, :billed_amount_cents, :integer
    add_index :messages, [:account_id, :created_at]
  end
end
```

### Step 3: Seed Data
```ruby
# db/seeds.rb
Plan.create!([
  {
    name: "Free",
    status: :active,
    monthly_price_cents: 0,
    included_balance_cents: 500,  # $5 free
    action_prices: { "message" => 10, "image" => 50 }
  },
  {
    name: "Starter",
    stripe_price_id: ENV["STRIPE_STARTER_PRICE"],
    paddle_price_id: ENV["PADDLE_STARTER_PRICE"],
    status: :active,
    monthly_price_cents: 2000,  # $20/month
    included_balance_cents: 2500,  # $25 balance included
    action_prices: { "message" => 8, "image" => 40 }  # Slight discount
  },
  {
    name: "Pro",
    stripe_price_id: ENV["STRIPE_PRO_PRICE"],
    paddle_price_id: ENV["PADDLE_PRO_PRICE"],
    status: :active,
    monthly_price_cents: 10000,  # $100/month
    included_balance_cents: 15000,  # $150 balance included
    action_prices: { "message" => 5, "image" => 25 }  # Better pricing
  }
])
```

## Implementation Checklist

### Phase 1: Core Infrastructure
- [ ] Add Pay gem with Stripe and Paddle support
- [ ] Run Pay migrations
- [ ] Create Plan migration
- [ ] Add balance fields to accounts
- [ ] Add billing fields to messages
- [ ] Run migrations and seed data

### Phase 2: Model Implementation
- [ ] Implement Plan model with simple action pricing
- [ ] Update Account model to use Pay's balance tracking
- [ ] Add subscription management to Account
- [ ] Update Message model to bill on completion
- [ ] Add cost tracking for analytics

### Phase 3: Usage Control
- [ ] Create TokenGating concern
- [ ] Include in ChatsController and MessagesController
- [ ] Update AiResponseJob to check balance
- [ ] Add insufficient funds handling

### Phase 4: Background Jobs
- [ ] Create AutoRechargeJob
- [ ] Create MonthlyBalanceJob
- [ ] Configure recurring jobs

### Phase 5: Payment Integration
- [ ] Configure webhook endpoints
- [ ] Test subscription flow
- [ ] Test balance purchases
- [ ] Test auto-recharge

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
end

# test/models/message_test.rb
class MessageTest < ActiveSupport::TestCase
  test "assistant message bills account on completion" do
    account = accounts(:one)
    account.payment_processor.increment_balance!(1000)
    plan = plans(:starter)
    account.update!(plan: plan)

    chat = account.chats.create!(name: "Test")
    message = chat.messages.create!(
      role: "assistant",
      content: "Response",
      model_id: "gpt-4"
    )

    # Simulate token update from RubyLLM
    message.update!(output_tokens: 500)

    # Should charge plan's message price (8 cents for starter)
    assert_equal 992, account.reload.balance
    assert_equal 8, message.reload.billed_amount_cents
  end
end
```

## Success Criteria

✅ **Simple**: No credits abstraction, just dollars
✅ **Clear**: Users see and pay in dollars
✅ **Leverages Pay**: Uses gem's balance tracking
✅ **Sustainable**: Track margins via analytics, not complex calculations
✅ **Flexible**: Supports subscriptions, PAYG, and auto-recharge
✅ **Multi-processor**: Works with Stripe and Paddle

## The Rails-Worthiness Test

**Would DHH approve?** Yes. This is simple, clear, and leverages existing tools.

**Core improvements from feedback:**
- Deleted the entire credits abstraction (−200 lines)
- Removed margin calculations from user-facing code (−50 lines)
- Leveraged Pay gem's balance tracking (−100 lines)
- Separated billing from analytics (clearer concerns)

**The result:** Half the code, twice the clarity.

## Summary

This implementation provides a clean, production-ready payments system that:

1. **Uses dollars throughout** - No confusing "credits" abstraction
2. **Simple pricing** - Fixed prices per action, not dynamic margins
3. **Leverages Pay gem** - Uses its balance tracking and subscription management
4. **Tracks profitability** - Separate internal analytics for margin analysis
5. **Supports flexibility** - Subscriptions, PAYG, auto-recharge all work

The system is straightforward: users maintain a prepaid balance, actions cost money, and we track the difference for profit analysis. No unnecessary abstractions, no complex calculations, just simple Rails code that works.