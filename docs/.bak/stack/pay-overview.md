# Pay Gem Documentation Overview

The Pay gem provides payment processing for Ruby on Rails applications with a unified interface across multiple payment providers.

## Documentation Structure

### Core Documentation

- **[Installation](./pay/installation.md)** - Setting up Pay in your Rails application
- **[Configuration](./pay/configuration.md)** - Credentials, webhooks, and email settings
- **[Customers](./pay/customers.md)** - Managing payment processor customers
- **[Payment Methods](./pay/payment-methods.md)** - Adding and updating payment methods
- **[Charges](./pay/charges.md)** - One-time payments and charges
- **[Subscriptions](./pay/subscriptions.md)** - Recurring billing and subscription management
- **[Webhooks](./pay/webhooks.md)** - Webhook configuration and event handling
- **[Testing](./pay/testing.md)** - Testing with the fake processor

### Payment Processor Guides

- **[Stripe](./pay/stripe.md)** - Complete Stripe integration including SCA, Checkout, Tax, and Billing Portal
- **[Paddle Billing](./pay/paddle-billing.md)** - Paddle Billing integration and configuration

## Quick Start

### 1. Install the gems

```ruby
# Gemfile
gem "pay", "~> 11.1"
gem "stripe", "~> 15.3"  # For Stripe
```

### 2. Run migrations

```bash
bin/rails pay:install:migrations
bin/rails db:migrate
```

### 3. Add to your model

```ruby
class User < ApplicationRecord
  pay_customer
end
```

### 4. Set payment processor

```ruby
user.set_payment_processor :stripe
```

### 5. Create a subscription

```ruby
user.payment_processor.subscribe(
  name: "default",
  plan: "price_monthly"
)
```

## Supported Payment Processors

- **Stripe** - Most popular, full-featured payment processor
- **Paddle Billing** - Merchant of record, handles EU VAT
- **Paddle Classic** - Legacy Paddle platform
- **Braintree** - PayPal-owned processor
- **Lemon Squeezy** - Software-focused payment platform
- **Fake Processor** - For testing without real API calls

## Key Features

- Unified API across all payment processors
- Subscription lifecycle management
- One-time charges and refunds
- Webhook handling
- Customer portal integration
- SCA/3D Secure support
- Tax handling
- Metered billing
- Testing support with fake processor

## Choosing a Payment Processor

### Stripe (Recommended for most apps)
- Most comprehensive features
- Best documentation and developer tools
- Stripe Checkout for easy implementation
- Full customer billing portal
- SCA compliant

### Paddle Billing
- Acts as merchant of record
- Handles EU VAT automatically
- Good for selling software globally
- Simpler compliance

### Fake Processor (For testing)
- No API calls required
- Fast test execution
- Secure (requires explicit permission)

## Important Notes

- Payment amounts are always in cents (e.g., 15_00 for $15.00)
- Webhooks are required for production use
- Some processors (Paddle Billing, Lemon Squeezy) create subscriptions via webhooks only
- Always use test/sandbox mode during development

## External Resources

- [Pay GitHub Repository](https://github.com/pay-rails/pay)
- [Stripe Documentation](https://stripe.com/docs)
- [Paddle Documentation](https://developer.paddle.com/)