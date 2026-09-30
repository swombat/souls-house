# Pay with Paddle Billing

Paddle Billing is Paddle's new subscription billing platform. It differs quite a bit from Paddle Classic. This guide covers implementing Paddle Billing in your Rails application using the Pay gem.

**Source:** [pay-rails/pay documentation](https://github.com/pay-rails/pay/blob/main/docs/paddle_billing/1_overview.md)
**Last Updated:** 2025-10-05

---

## Table of Contents

1. [Overview](#overview)
2. [Key Differences from Paddle Classic](#key-differences-from-paddle-classic)
3. [Configuration](#configuration)
4. [Creating Customers](#creating-customers)
5. [Subscriptions](#subscriptions)
6. [Charges](#charges)
7. [Payment Methods](#payment-methods)
8. [Webhooks](#webhooks)
9. [Testing with Sandbox](#testing-with-sandbox)

---

## Overview

Paddle Billing is Paddle's new subscription billing platform with several important characteristics:

- **Checkout only happens via iFrame or hosted page**
- **Cancelling a subscription cannot be resumed**
- **Payment methods can only be updated while a subscription is active**

### Prices & Plans

Paddle introduced Products & Prices to support more payment options. Previously, they had Products and Plans separated.

---

## Key Differences from Paddle Classic

### Migration Note

Paddle Classic is now `paddle_classic` and Paddle Billing is `paddle_billing`. To migrate existing Paddle customers:

```ruby
Pay::Customer.where(processor: :paddle).update_all(processor: :paddle_classic)
```

### How Paddle Billing Works

Paddle Billing now works similar to Stripe:
- You create a customer, which subscriptions belong to
- Subscriptions are not created through the API, but through webhooks
- When a subscription is created, Paddle will send a webhook to your application
- Pay will automatically create the subscription for you

---

## Configuration

### Setting Up Paddle Billing

Enable Paddle Billing in your Pay configuration (`config/initializers/pay.rb`):

```ruby
Pay.setup do |config|
  config.enabled_processors = [:paddle_billing]
  # Other configuration options...
end
```

### Paddle API Key

You can generate an API key at:
- **Production:** https://vendors.paddle.com/authentication-v2
- **Sandbox:** https://sandbox-vendors.paddle.com/authentication-v2

### Paddle Client Token

Client side tokens are used to work with Paddle.js in your frontend. You can generate one using the same links above.

### Paddle Environment

Paddle has two environments: **Sandbox** and **Production**.

To use the Sandbox environment, set the Environment value to `sandbox`. By default, this is set to `production`.

### Paddle Signing Secret

Paddle uses a signing secret to verify that webhooks are coming from Paddle. You can find this after creating a webhook in the Paddle dashboard:

- **Production:** https://vendors.paddle.com/notifications
- **Sandbox:** https://sandbox-vendors.paddle.com/notifications

### Environment Variables

Pay will automatically look for the following environment variables, or the equivalent Rails credentials:

- `PADDLE_BILLING_ENVIRONMENT`
- `PADDLE_BILLING_API_KEY`
- `PADDLE_BILLING_CLIENT_TOKEN`
- `PADDLE_BILLING_SIGNING_SECRET`

### Rails Credentials Configuration (Recommended)

```yaml
paddle_billing:
  client_token: aaaa
  api_key: yyyy
  signing_secret: pdl_ntfset...
  environment: sandbox  # or production
```

---

## Creating Customers

Paddle now works similar to Stripe. You create a customer, which subscriptions belong to.

### Set the Payment Processor

```ruby
@user.set_payment_processor :paddle_billing
```

### Create the Customer on Paddle

```ruby
@user.payment_processor.api_record
```

This method will:
- Create a new customer on the payment processor if no `processor_id` exists
- Retrieve the existing customer from the payment processor if `processor_id` is set

The method returns a `Paddle::Customer` object:

```ruby
@user.payment_processor.api_record
#=> #<Paddle::Customer>
```

### Retrieve a Customer

To retrieve or create a Paddle customer:

```ruby
@user.payment_processor.customer
```

---

## Subscriptions

As with Paddle Classic, Paddle Billing does not allow you to create a subscription through the API.

Instead, Pay uses webhooks to create the subscription in the database. The Paddle `customer` field is required during checkout to associate the subscription with the correct `Pay::Customer`.

### Creating a Subscription via Checkout

First, retrieve/create a Paddle customer:

```ruby
@user.payment_processor.customer
```

Then using either the Javascript `Paddle.Checkout.open` method:

```javascript
Paddle.Checkout.open({
  customer: {
    id: "<%= @user.payment_processor.processor_id %>",
  },
  items: [
    {
      // The Price ID of the subscription plan
      priceId: "pri_abc123",
      quantity: 1
    }
  ],
})
```

Or with Paddle Button Checkout:

```html
<a href='#'
   class='paddle_button'
   data-display-mode='overlay'
   data-locale='en'
   data-items='[
     {
       "priceId": "pri_abc123",
       "quantity": 1
     }
   ]'
   data-customer-id="<%= @user.payment_processor.processor_id %>"
>
  Subscribe
</a>
```

### Subscription Lifecycle

- Subscriptions are created via webhooks when Paddle confirms the subscription
- **Cancelling a subscription cannot be resumed** (unlike Stripe)
- Pay will automatically create and update the subscription in your database

---

## Charges

### Creating Charges

When creating charges with Paddle, they need to be approved by the customer. This is done by passing the Paddle Transaction ID to a Paddle.js checkout.

```ruby
@user.payment_processor.charge(15_00) # $15.00 USD
```

With custom parameters:

```ruby
@user.payment_processor.charge(15_00, currency: "cad")
```

Or with Paddle-specific options:

```ruby
@user.payment_processor.charge(0, {
  items: [
    {
      quantity: 1,
      price_id: "pri_abc123"
    }
  ],
  # include additional fields here
})
```

### Error Handling

On failure, a `Pay::Error` will be raised with payment failure details.

### Retrieving Invoices/Receipts

**Important:** Paddle Billing doesn't provide a receipt URL like Paddle Classic did.

To retrieve a PDF invoice for a transaction, an API request is required:

```ruby
Paddle::Transaction.invoice(id: @charge.processor_id)
```

This will return a URL to the PDF invoice. **Note:** This URL is not permanent and will expire after a short period of time.

---

## Payment Methods

### Updating Payment Methods

For updating payment method details on Paddle, a transaction ID is required.

First, generate a transaction:

```ruby
subscription = @user.payment_processor.subscription(name: "plan name")
transaction = subscription.payment_method_transaction
```

Then pass it through Paddle.js:

```html
<a href="#"
   class="paddle_button"
   data-display-mode="overlay"
   data-theme="light"
   data-locale="en"
   data-transaction-id="<%= transaction.id %>"
>
  Update Payment Details
</a>
```

This will open the Paddle overlay and allow the user to update their payment details.

**Important:** Payment methods can only be updated while a subscription is active.

### Importing Payment Methods

If a Payment Method doesn't exist in Pay, you can create it from Paddle Billing:

```ruby
Pay::PaddleBilling::PaymentMethod.sync_from_transaction(
  pay_customer: @user.payment_processor,
  transaction: "txn_abc123"
)
```

If a Payment Method already exists with the token, it will be updated with the latest details from Paddle.

---

## Webhooks

### Webhook URL

Webhooks are mounted at:

```
https://example.org/pay/webhooks/paddle_billing
```

Configure this URL in the Paddle dashboard:
- **Production:** https://vendors.paddle.com/notifications
- **Sandbox:** https://sandbox-vendors.paddle.com/notifications

### Webhook Events

Event names are prefixed with the provider name:

```ruby
"paddle_billing.subscription.created"
"paddle_billing.subscription.updated"
"paddle_billing.transaction.completed"
# etc.
```

### Custom Webhook Listeners

You can add custom webhook listeners by subscribing to specific event types in your Rails application.

### Webhook Security

Paddle uses the signing secret to verify that webhooks are coming from Paddle. Configure this in your credentials or environment variables:

- `PADDLE_BILLING_SIGNING_SECRET`
- Or in credentials: `paddle_billing.signing_secret`

---

## Testing with Sandbox

### Enabling Sandbox Mode

Set the environment to sandbox in your configuration:

**Environment Variable:**
```bash
PADDLE_BILLING_ENVIRONMENT=sandbox
```

**Rails Credentials:**
```yaml
paddle_billing:
  environment: sandbox
  api_key: your_sandbox_api_key
  client_token: your_sandbox_client_token
  signing_secret: your_sandbox_signing_secret
```

### Sandbox Resources

- **Sandbox Dashboard:** https://sandbox-vendors.paddle.com/
- **API Key Generation:** https://sandbox-vendors.paddle.com/authentication-v2
- **Webhook Configuration:** https://sandbox-vendors.paddle.com/notifications

### Frontend Integration with Sandbox

When using Paddle.js in development/sandbox mode, ensure you're using the sandbox client token and that Paddle.js is configured for the sandbox environment.

### Testing Workflow

1. Create a customer in sandbox mode
2. Use sandbox price IDs for subscriptions
3. Test webhooks using the sandbox webhook URL
4. Verify transactions in the Paddle sandbox dashboard
5. Test payment method updates while subscriptions are active

### Known Limitations

- Payment methods can only be updated while a subscription is active
- Cancelled subscriptions cannot be resumed
- Receipt URLs are not permanent and expire quickly
- Subscriptions must be created via checkout (not API)

---

## Additional Resources

- **Pay Gem Documentation:** https://github.com/pay-rails/pay
- **Paddle Billing API Docs:** https://developer.paddle.com/api-reference/overview
- **Paddle.js Documentation:** https://developer.paddle.com/paddlejs/overview
- **Paddle Dashboard (Production):** https://vendors.paddle.com/
- **Paddle Dashboard (Sandbox):** https://sandbox-vendors.paddle.com/

---

## Summary

Paddle Billing integration with Pay provides:

- ✅ Customer management similar to Stripe
- ✅ Webhook-based subscription creation
- ✅ iFrame and hosted page checkouts
- ✅ Payment method updates (while subscription active)
- ✅ Transaction-based charging
- ✅ Sandbox environment for testing
- ⚠️ No API-based subscription creation
- ⚠️ Cancelled subscriptions cannot be resumed
- ⚠️ Payment methods only updatable with active subscription
- ⚠️ Receipt URLs are temporary

This comprehensive guide should help you implement Paddle Billing in your Rails application using the Pay gem.
