# Pay Gem - Stripe Integration Documentation

This document compiles all Stripe-specific documentation for the Pay gem from the official pay-rails/pay repository.

**Source**: https://github.com/pay-rails/pay/tree/main/docs/stripe
**Compiled**: 2025-10-05

---

## Table of Contents

1. [Overview](#overview)
2. [Credentials](#credentials)
3. [JavaScript](#javascript)
4. [Strong Customer Authentication (SCA)](#strong-customer-authentication-sca)
5. [Webhooks](#webhooks)
6. [Metered Billing](#metered-billing)
7. [Stripe Tax](#stripe-tax)
8. [Stripe Checkout](#stripe-checkout)
9. [Stripe Billing Portal](#stripe-billing-portal)
10. [Customer Reconciliation](#customer-reconciliation)

---

## Overview

Stripe has multiple options for payments:
- [Stripe Checkout](https://stripe.com/payments/checkout) - Hosted pages for payments (you'll redirect users to Stripe)
- [Stripe Elements](https://stripe.com/payments/elements) - Payment fields on your site

### Prices & Plans

Stripe introduced Products & Prices to support more payment options. Previously, they had a concept called Plan that was for subscriptions. Pay supports both `Price IDs` and `Plan IDs` when subscribing.

```ruby
@user.payment_processor.subscribe(plan: "price_1234")
@user.payment_processor.subscribe(plan: "plan_1234")
```

Multiple subscription items in a single subscription can be passed in as `items`:

```ruby
@user.payment_processor.subscribe(
  items: [
    {price: "price_1234"},
    {price: "price_5678"}
  ]
)
```

See: https://stripe.com/docs/api/subscriptions/create

### Promotion Codes

Promotion codes are customer-facing coupon codes that can be applied in several ways.

You can apply a promotion code on the Stripe::Customer to have it automatically apply to all Subscriptions.

```ruby
@user.payment_processor.update_api_record(promotion_code: "promo_1234")
```

Promotion codes can also be applied directly to a subscription:

```ruby
@user.payment_processor.subscribe(plan: "plan_1234", promotion_code: "promo_1234")
```

Stripe Checkout can also accept promotion codes by enabling the flag:

```ruby
@checkout_session = current_user.payment_processor.checkout(
  mode: "payment",
  line_items: "price_1ILVZaKXBGcbgpbZQ26kgXWG",
  allow_promotion_codes: true
)
```

### Failed Payments

Subscriptions that fail payments will be set to `past_due` status.

If all attempts are exhausted, Stripe will either leave the subscription as `past_due`, cancel it, or mark it as `unpaid` depending on your Stripe account settings.

---

## Credentials

To use Stripe with Pay, you'll need to add your API keys and Signing Secret(s) to your Rails app. See [Configuring Pay](/docs/2_configuration.md#credentials) for instructions on adding credentials or ENV Vars.

### API Keys

You can create (or find) your Stripe private (secret) and public (publishable) keys in the [Stripe Dashboard](https://dashboard.stripe.com/test/apikeys).

> **NOTE**: By default we're linking to the "test mode" page for API keys so you can get up and running in development. When you're ready to deploy to production, you'll have to toggle the "test mode" option off and repeat all steps again for live payments.

### Signing Secrets

Webhooks use signing secrets to verify the webhook was sent by Stripe. Check out [Webhooks](#webhooks) doc for detailed instructions on where/how to get these.

#### Dashboard

The [Webhooks](https://dashboard.stripe.com/test/webhooks/) page on Stripe contains all the defined endpoints and their signing secrets.

#### Stripe CLI (Development)

View the webhook signing secret used by the Stripe CLI by running:

```sh
stripe listen --print-secret
```

---

## JavaScript

Here's some example Javascript for handling your payment forms with [Stripe.js](https://docs.stripe.com/js) and [Hotwire / Turbo](https://hotwired.dev).

### Form HTML

With SCA, each of your actions client-side need a PaymentIntent or SetupIntent ID depending on what you're doing. If you're charging a card immediately, you must provide a PaymentIntent ID. For trials or updating the card on file, you should use a SetupIntent ID.

We recommend setting these IDs as data attributes on your `form`.

You can use `data-payment-intent` or `data-setup-intent` depending on if you're making a payment (PaymentIntent) or setting up a card to use later (SetupIntent).

```ruby
# Your controller if you are using a SetupIntent:

def new
  ...
  @setup_intent = current_user.payment_processor.create_setup_intent
  ...
end
```

```erb
<%= form_with url: subscription_path,
  id: "payment-form",
  data: {
    payment_intent: @payment_intent,
    setup_intent: @setup_intent.client_secret
  } do |form| %>

  <label>Credit or debit card</label>
  <div id="card-element" class="field"></div>

  <%= form.submit %>
<% end %>
```

Make sure any payment forms have `id="payment-form"` on them. This is how the Javascript finds the form to add Stripe to it.

Card fields should have an ID of `id="card-element"` to denote trigger Stripe JS to be applied to the form.

### Stripe Public Key

A meta tag with `name="stripe-key"` should include the Stripe public key as the `content` attribute.

```erb
<%= tag.meta name: "stripe-key", content: Pay::Stripe.public_key %>
<script src="https://js.stripe.com/v3/" defer></script>
```

### Javascript Implementation

When a form is submitted, the card will be tokenized into a Payment Method ID and submitted with your form. The Javascript handles the Stripe tokenization automatically.

---

## Strong Customer Authentication (SCA)

Our Stripe integration **requires** the use of Payment Method objects to correctly support Strong Customer Authentication with Stripe. If you've previously been using card tokens, you'll need to upgrade your Javascript integration.

Subscriptions that require SCA are marked as `incomplete` by default. Once payment is authenticated, Stripe will send a webhook updating the status of the subscription. You'll need to use the [Stripe CLI](https://github.com/stripe/stripe-cli) to forward webhooks to your application to make sure your subscriptions work correctly for SCA payments.

```shell
stripe listen --forward-to localhost:3000/pay/webhooks/stripe
```

You should use `stripe.confirmCardSetup` on the client to collect card information anytime you want to save the card and charge them later (adding a card, then charging them on the next page for example). Use `stripe.confirmCardPayment` if you'd like to charge the customer immediately (think checking out of a shopping cart).

The Javascript also needs to have a PaymentIntent or SetupIntent created server-side and the ID passed into the Javascript to do this. That way it knows how to safely handle the card tokenization if it meets the SCA requirements.

### SCA Payment Confirmations

Sometimes you'll have a payment that requires extra authentication. In this case, Pay provides a webhook and action for handling these payments. It will automatically email the customer and provide a link with the PaymentIntent ID in the url where the customer will be asked to fill out their name and card number to confirm the payment. Once done, they'll be redirected back to your application.

### Pay::ActionRequired

When a charge or subscription needs SCA confirmation, Pay will raise a `Pay::ActionRequired` error. You can use this to redirect to the SCA confirm page.

```ruby
def create
  @user.charge(10_00)
  # or @user.subscribe(plan: "x")

rescue Pay::ActionRequired => e
  # Redirect to the Pay SCA confirmation page
  redirect_to pay.payment_path(e.payment.id)

rescue Pay::Error => e
  # Display any other errors
  flash[:alert] = e.message
  redirect_to root_path
end
```

---

## Webhooks

Pay listens to Stripe's webhooks to keep the local payments data in sync.

For development, we use the Stripe CLI to forward webhooks to our local server. In production, webhooks are sent directly to our app's domain.

### Development webhooks with the Stripe CLI

You can use the [Stripe CLI](https://stripe.com/docs/stripe-cli) to test and forward webhooks in development.

```shell
stripe login
stripe listen --forward-to localhost:3000/pay/webhooks/stripe
```

### Production webhooks for Stripe

1. Visit https://dashboard.stripe.com/webhooks/create.
2. Use the default "Add an endpoint" form.
3. Set "endpoint URL" to https://example.org/pay/webhooks/stripe (Replace `example.org` with your domain)
4. Under "select events to listen to" choose "Select all events" and click "Add events". Or if you want to listen to specific events, check out [events we listen to](#events).
5. Finalize the creation of the endpoint by clicking "Add endpoint".
6. After creating the webhook endpoint, click "Reveal" under the heading "Signing secret". Copy the `whsec_...` value to wherever you have configured your keys for Stripe as instructed in [Credentials](#credentials) section.

### Events

Pay requires the following webhooks to properly sync charges and subscriptions as they happen.

```ruby
charge.succeeded
charge.refunded
charge.updated

payment_intent.succeeded

invoice.upcoming
invoice.payment_action_required
invoice.payment_failed

customer.subscription.created
customer.subscription.updated
customer.subscription.deleted
customer.subscription.trial_will_end
customer.updated
customer.deleted

payment_method.attached
payment_method.updated
payment_method.automatically_updated
payment_method.detached

account.updated

checkout.session.completed
checkout.session.async_payment_succeeded
```

---

## Metered Billing

Metered billing are subscriptions where the price fluctuates monthly. For example, you may spin up servers on DigitalOcean, shut some down, and keep others running. Metered billing allows you to report usage of these servers and charge according to what was used.

```ruby
@user.payment_processor.subscribe(plan: "price_metered_billing_id")
```

This will create a new metered billing subscription. You can then create meter events to bill for usage:

```ruby
@user.payment_processor.create_meter_event(:api_request, payload: { value: 1 })
```

### Failed Payments

If a metered billing subscription fails, it will fall into a `past_due` state.

After payment attempts fail, Stripe will either leave the subscription alone, cancel it, or mark it as `unpaid` depending on the settings in your Stripe account. We recommend marking the subscription as `unpaid`.

You can notify your user to update their payment method. Once they do, you can retry the open payment to bring their subscription back into the active state.

### Migrating from Usage Records to Billing Meters

Follow the Stripe migration guide here: https://docs.stripe.com/billing/subscriptions/usage-based-legacy/migration-guide

While transitioning, you'll need to continue reporting Usage Records and Meters at the same time. You'll need to use Pay v9 until this is completed since Stripe v15 removes Usage Records entirely.

Stripe will raise an error when creating a Usage Record for a Billing Meter subscription, so you can rescue from `Stripe::InvalidRequestError` to ignore those.

Here's an example Rake task to migrate from old prices to new prices:

```ruby
task migrate_to_meters: :environment do
  old_price = "price_1234"
  new_price = "price_5678"

  ::Stripe::Subscription.list({price: old_price, expand: ["data.schedule"]}).auto_paging_each do |stripe_subscription|
    puts "Migrating #{stripe_subscription.id}..."

    # Create a subscription schedule if not present
    if stripe_subscription.schedule.nil?
      ::Stripe::SubscriptionSchedule.create({
        from_subscription: stripe_subscription.id
      })
    end
  end
end
```

---

## Stripe Tax

Collecting tax is easy with Stripe and Pay. You'll need to enable Stripe Tax in the dashboard and configure your Tax registrations where you're required to collect tax.

### Set Address on Customer

An address is required on the Customer for tax calculations.

```ruby
class User < ApplicationRecord
  pay_customer stripe_attributes: :stripe_attributes

  def stripe_attributes(pay_customer)
    {
      address: {
        country: "US",
        postal_code: "90210"
      }
    }
  end
end
```

To update the customer address anytime it's changed, call the following method:

```ruby
@user.payment_processor.update_api_record
```

This will make an API request to update the Stripe::Customer with the current `stripe_attributes`.

See the Stripe Docs for more information about update tax addresses on a customer:
https://stripe.com/docs/api/customers/update#update_customer-tax-ip_address

### Subscribe with Automatic Tax

To enable tax for a subscription, you can pass in `automatic_tax`:

```ruby
@user.payment_processor.subscribe(plan: "growth", automatic_tax: { enabled: true })
```

For Stripe Checkout, you can do the same thing:

```ruby
@user.payment_processor.checkout(mode: "payment", line_items: "price_1234", automatic_tax: { enabled: true })
@user.payment_processor.checkout(mode: "subscription", line_items: "price_1234", automatic_tax: { enabled: true })
```

### Pay::Charges

Taxes are saved on the `Pay::Charge` model.

- `tax` - the total tax charged
- `total_tax_amounts` - The tax rates for each jurisdiction on the charge

---

## Stripe Checkout

[Stripe Checkout](https://stripe.com/docs/payments/checkout) allows you to simply redirect to Stripe for handling payments. The main benefit is that it's super fast to setup payments in your application, they're SCA compatible, and they will get improved automatically by Stripe.

> **WARNING**: You need to configure webhooks before using Stripe Checkout otherwise your application won't be updated with the correct data.
>
> See [Webhooks](#webhooks) section on how to do that.

### How to use Stripe Checkout with Pay

Choose the checkout button mode you need and pass any required arguments. Read the [Stripe Checkout Session API docs](https://stripe.com/docs/api/checkout/sessions/create) to see what options are available.

```ruby
class SubscriptionsController < ApplicationController
  def checkout
    # Make sure the user's payment processor is Stripe
    current_user.set_payment_processor :stripe

    # One-time payments (https://stripe.com/docs/payments/accept-a-payment)
    @checkout_session = current_user.payment_processor.checkout(
      mode: "payment",
      line_items: "price_1ILVZaKXBGcbgpbZQ26kgXWG"
    )

    # Or Subscriptions (https://stripe.com/docs/billing/subscriptions/build-subscription)
    @checkout_session = current_user.payment_processor.checkout(
      mode: 'subscription',
      locale: I18n.locale,
      line_items: [{
        price: 'price_1ILVZaKXBGcbgpbZQ26kgXWG',
        quantity: 4
      }],
      subscription_data: {
        trial_period_days: 15,
        metadata: {
          pay_name: "base" # Optional. Overrides the Pay::Subscription name attribute
        },
      },
      success_url: root_url,
      cancel_url: root_url
    )

    # Or Setup a Payment Method (https://stripe.com/docs/payments/save-and-reuse)
    @checkout_session = current_user.payment_processor.checkout(
      mode: "setup",
      success_url: root_url,
      cancel_url: root_url
    )

    # Redirect to checkout
    redirect_to @checkout_session.url, allow_other_host: true, status: :see_other
  end
end
```

### Important Notes

1. **Turbo Compatibility**: Due to a bug in the browser's fetch implementation, you will need to disable Turbo if redirecting to Stripe checkout server-side:

```erb
<%= link_to "Checkout", checkout_path, data: { turbo: false } %>
```

2. **Success Page Handling**: The `stripe_checkout_session_id` param will be included on success and cancel URLs automatically, allowing you to lookup the checkout session on your success page and confirm the payment was successful before fulfilling the customer's purchase.

### Checkout Options

You can pass any valid Stripe Checkout Session options to the `checkout` method:

- `mode` - "payment", "subscription", or "setup"
- `line_items` - Array of price items or a single price ID
- `success_url` - URL to redirect to after successful checkout
- `cancel_url` - URL to redirect to if checkout is cancelled
- `allow_promotion_codes` - Boolean to enable promotion code field
- `automatic_tax` - Hash with `enabled: true` to enable automatic tax
- `locale` - Language locale for the checkout page
- `subscription_data` - Additional subscription options including trial_period_days and metadata

---

## Stripe Billing Portal

The [Stripe Billing Portal](https://stripe.com/docs/billing/subscriptions/integrating-customer-portal) provides a hosted page where customers can manage their subscriptions, payment methods, and view their billing history.

### How to use Stripe Billing Portal with Pay

```ruby
class SubscriptionsController < ApplicationController
  def index
    @portal_session = current_user.payment_processor.billing_portal

    # You can customize the billing_portal return_url (default is root_url):
    # @portal_session = current_user.payment_processor.billing_portal(return_url: your_url)
  end
end
```

Then link to it in your view:

```erb
<%= link_to "Billing Portal", @portal_session.url %>
```

Or redirect to it in your controller:

```ruby
redirect_to @portal_session.url, allow_other_host: true, status: :see_other
```

### Key Features

The Stripe Billing Portal allows customers to:
- Update their payment methods
- Change their subscription plan
- Cancel or pause their subscription
- View their billing history and invoices
- Download receipts

### Prerequisites

- You need to configure webhooks before using the Stripe Billing Portal
- The billing portal must be enabled in your Stripe Dashboard settings
- By default, when the user is finished managing their subscription, they can return to the root URL of your application
- You can customize this return URL by passing it as an argument to the `billing_portal` method

### Configuration Options

The `billing_portal` method accepts the following options:

- `return_url` - URL where customers will be redirected when they leave the portal (defaults to `root_url`)

Example with custom return URL:

```ruby
@portal_session = current_user.payment_processor.billing_portal(
  return_url: subscriptions_url
)
```

---

## Customer Reconciliation

Pay tracks customers for each payment processor using the `Pay::Customer` model, but the payment processor logic for customers varies between providers. When using Stripe with Pay, a customer object must exist for a model with `pay_customer` for charges and subscriptions to occur. If a `Pay::Customer` does not exist, one will be created automatically when attempting to operate upon subscriptions and charges.

When creating the new `Pay::Customer`, Pay does not attempt to reconcile the attributes used to create a `Pay::Customer` with existing Stripe customers. As a result, there is a possibility that duplicate Stripe customers may exist with the same attributes (e.g. email) if the application using Pay does not manually reconcile existing Stripe customers with the `Pay::Customer`s.

### Manual Reconciliation

The Stripe API can be used to list all existing Stripe customers. This allows the application to implement the necessary logic for creating and associating `Pay::Customer`s within the application.

There are two methods available to associate existing Stripe customers with a `pay_customer` model:

#### set_payment_processor

Finds or creates a `Pay::Customer` and marks it as the default for the model (the default `Pay::Customer` is the `Model.payment_processor`). It also removes the default flag from other `Pay::Customer`s and `Pay::PaymentMethod`s.

Example:
```ruby
User.set_payment_processor("stripe", processor_id: "cus_O1PngYajzbTEST")
```

#### add_payment_processor

Finds or creates a `Pay::Customer`, updating the `Pay::Customer` with the attributes provided. This method does not mutate default flags for existing `Pay::Customer`s that exist.

Example:
```ruby
User.add_payment_processor("stripe", processor_id: "cus_O1PngYajzbTEST")
```

### Automated Reconciliation

Automated reconciliation is possible through the use of ActiveRecord callbacks.

**Note**: Care should be taken with automated reconciliation, as automated reconciliation may have security and privacy implications on your application. Automatically associating a Pay customer to a `pay_customer` model based on unverified attributes could be problematic.

---

## Additional Resources

- [Pay Gem GitHub Repository](https://github.com/pay-rails/pay)
- [Stripe Documentation](https://stripe.com/docs)
- [Stripe API Reference](https://stripe.com/docs/api)
- [Stripe Checkout Documentation](https://stripe.com/docs/payments/checkout)
- [Stripe Billing Portal Documentation](https://stripe.com/docs/billing/subscriptions/integrating-customer-portal)
- [Stripe Tax Documentation](https://stripe.com/docs/tax)
- [Strong Customer Authentication (SCA) Guide](https://stripe.com/docs/strong-customer-authentication)

---

**Last Updated**: 2025-10-05
**Pay Gem Version**: Latest (main branch)
**Stripe API Version**: Latest supported by Pay gem
