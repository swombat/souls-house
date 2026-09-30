# Routes & Webhooks

Routes are automatically mounted to `/pay` by default.

## Stripe SCA Confirm Page

We provide a route for confirming Stripe SCA payments at `/pay/payments/:payment_intent_id`

See [Stripe SCA docs](/pay-rails/pay/blob/main/docs/stripe/4_sca.md)

## Webhooks

Pay comes with a bunch of different webhook handlers built-in. Each payment processor has different requirements for handling webhooks and we've implemented all the basic ones for you.

### Routes

Webhooks are automatically mounted at `/pay/webhooks/:provider`

To configure webhooks on your payment processor, use the following URLs while replacing `example.org` with your own domain:

- **Stripe** - `https://example.org/pay/webhooks/stripe`
- **Braintree** - `https://example.org/pay/webhooks/braintree`
- **Paddle Billing** - `https://example.org/pay/webhooks/paddle_billing`
- **Paddle Classic** - `https://example.org/pay/webhooks/paddle_classic`
- **Lemon Squeezy** - `https://example.org/pay/webhooks/lemon_squeezy`

#### Mount path

If you have a catch all route (for 404s, etc) and need to control where/when the webhook endpoints mount, you will need to disable automatic mounting and mount the engine above your catch all route.

```ruby
# config/initializers/pay.rb
config.automount_routes = false
```

```ruby
# config/routes.rb
mount Pay::Engine, at: '/other-path'
```

If you just want to modify where the engine mounts it's routes then you can change the path.

```ruby
# config/initializers/pay.rb
config.routes_path = '/other-path'
```

### Event Naming

Since we support multiple payment providers, each event type is prefixed with the payment provider:

```ruby
"stripe.charge.succeeded"
"braintree.subscription_charged_successfully"
"paddle_billing.subscription.created"
"paddle_classic.subscription_created"
"lemon_squeezy.order_created"
```

### Handling Webhooks

To add your own custom webhooks, you can subscribe to the Pay events using `ActiveSupport::Notifications`:

```ruby
# config/initializers/pay.rb

# Listen to all events
ActiveSupport::Notifications.subscribe /pay\..*/ do |event|
  # event.name #=> "pay.charge.succeeded"
  # event.payload[:pay_charge] #=> Pay::Charge object
end

# Listen to Stripe events
ActiveSupport::Notifications.subscribe /^stripe\./ do |event|
  # event.name #=> "stripe.charge.succeeded"
  # event.payload[:object] #=> Stripe::Event object
  # event.payload[:pay_charge] #=> Pay::Charge object
end

# Listen to Paddle Billing events
ActiveSupport::Notifications.subscribe /^paddle_billing\./ do |event|
  # event.name #=> "paddle_billing.subscription.created"
  # event.payload[:event] #=> Paddle::Event object
end

# Listen to a specific Stripe event
ActiveSupport::Notifications.subscribe "stripe.charge.succeeded" do |event|
  # event.name #=> "stripe.charge.succeeded"
  # event.payload[:object] #=> Stripe::Event object
  # event.payload[:pay_charge] #=> Pay::Charge object
end
```

This allows you to add any custom functionality to handle webhooks like emailing users, scheduling reports, etc.

#### Event Payload

The event payload contains the payment provider's event object along with the associated Pay object (if applicable):

```ruby
{
  event: "processor.event.name",
  object: <ProcessorEvent>,
  pay_charge: <Pay::Charge>,
  pay_subscription: <Pay::Subscription>,
  pay_payment_method: <Pay::PaymentMethod>
}
```

Not all events will have all of these. For example, a `charge.succeeded` event will have a `pay_charge` but not a `pay_subscription`.

### Webhook Processors

Each payment processor has it's own webhook processor. You can view the code for these to see exactly which events are handled:

- [Stripe](https://github.com/pay-rails/pay/blob/main/lib/pay/stripe/webhooks.rb)
- [Braintree](https://github.com/pay-rails/pay/blob/main/lib/pay/braintree/webhooks.rb)
- [Paddle Billing](https://github.com/pay-rails/pay/blob/main/lib/pay/paddle_billing/webhooks.rb)
- [Paddle Classic](https://github.com/pay-rails/pay/blob/main/lib/pay/paddle_classic/webhooks.rb)
- [Lemon Squeezy](https://github.com/pay-rails/pay/blob/main/lib/pay/lemon_squeezy/webhooks.rb)

#### Custom Webhook Processors

If you'd like to customize or add additional webhook handlers for a payment processor, you can define your own webhook processor class.

```ruby
# config/initializers/pay.rb
config.webhooks.stripe = MyCustomStripeWebhookProcessor
```

You can subclass the default processor and override or add new methods:

```ruby
class MyCustomStripeWebhookProcessor < Pay::Stripe::Webhooks::Subscription
  # Override the default handler
  def handle_subscription_created
    # Custom code here
  end

  # Add a new handler
  def handle_subscription_paused
    # Custom code here
  end
end
```

Or you can create a processor from scratch:

```ruby
class MyCustomStripeWebhookProcessor
  def initialize(event)
    @event = event
  end

  def call
    case @event.type
    when "customer.subscription.created"
      handle_subscription_created
    when "customer.subscription.updated"
      handle_subscription_updated
    end
  end

  private

  def handle_subscription_created
    # Custom code here
  end

  def handle_subscription_updated
    # Custom code here
  end
end
```

### Testing Webhooks

Pay includes webhook tests for each payment processor. You can run these tests using:

```bash
rails test
```

To test webhooks in development, you can use a tool like [ngrok](https://ngrok.com) to create a tunnel to your local server. Then configure your payment processor to send webhooks to the ngrok URL.

```bash
ngrok http 3000
```

Then in your payment processor dashboard, configure the webhook URL to be:

```
https://abc123.ngrok.io/pay/webhooks/stripe
```

### Stripe CLI

Stripe provides a CLI tool for forwarding webhook events to your local development server.

Install the Stripe CLI: https://stripe.com/docs/stripe-cli

Then run:

```bash
stripe listen --forward-to localhost:3000/pay/webhooks/stripe
```

This will forward all Stripe webhook events to your local server. You can also trigger specific events:

```bash
stripe trigger customer.subscription.created
```

### Webhook Signatures

Pay automatically verifies webhook signatures for all payment processors. This ensures that the webhooks are actually coming from the payment processor and not a malicious third party.

If signature verification fails, a `Pay::InvalidWebhookSignature` exception will be raised and a 400 response will be returned.

#### Stripe

Stripe webhook signatures are verified using the `Stripe::Webhook.construct_event` method.

You must set the `STRIPE_WEBHOOK_SECRET` environment variable or configure it in `config/initializers/pay.rb`:

```ruby
config.stripe.signing_secret = "whsec_..."
```

You can find your webhook signing secret in your Stripe Dashboard under Developers > Webhooks > [Select endpoint] > Signing secret

#### Paddle Billing

Paddle Billing webhook signatures are verified using the Paddle Ruby SDK.

You must set the `PADDLE_BILLING_WEBHOOK_SECRET` environment variable or configure it in `config/initializers/pay.rb`:

```ruby
config.paddle_billing.webhook_secret = "pdl_ntfset_..."
```

#### Lemon Squeezy

Lemon Squeezy webhook signatures are verified using the Lemon Squeezy Ruby SDK.

You must set the `LEMON_SQUEEZY_WEBHOOK_SECRET` environment variable or configure it in `config/initializers/pay.rb`:

```ruby
config.lemon_squeezy.signing_secret = "..."
```

### Webhook Debugging

If webhooks aren't working as expected, you can check the Rails logs to see if they're being received and processed correctly.

You can also check your payment processor's dashboard to see the webhook delivery attempts and responses.

If webhooks are failing, make sure:

1. The webhook URL is publicly accessible (not localhost unless using ngrok or Stripe CLI)
2. The webhook secret is configured correctly
3. Your firewall/hosting provider isn't blocking webhook requests
4. The webhook signature verification is passing

### Disabling Webhooks

If you need to disable webhooks entirely, you can set `config.automount_routes = false` in `config/initializers/pay.rb` to prevent the webhook routes from being mounted.

You can also disable specific webhook handlers by not subscribing to them with `ActiveSupport::Notifications`.
