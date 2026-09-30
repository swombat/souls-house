# Configuring Pay

Pay comes with a lot of configuration out of the box for you, but you'll need to add your API tokens for your payment provider.

## Credentials

Pay automatically looks up credentials for each payment provider. We recommend storing them in the Rails credentials.

##### Rails Credentials

You'll need to add your API keys to your Rails credentials. You can do this by running:

```shell
rails credentials:edit --environment=development
```

They should be formatted like the following:

```yaml
stripe:
  private_key: xxxx
  public_key: yyyy
  webhook_receive_test_events: true
  signing_secret:
    - aaaa
    - bbbb
braintree:
  private_key: xxxx
  public_key: yyyy
  merchant_id: aaaa
  environment: sandbox
paddle_billing:
  client_token: aaaa
  api_key: yyyy
  signing_secret: pdl_ntfset...
  environment: sandbox
paddle_classic:
  vendor_id: xxxx
  vendor_auth_code: yyyy
  public_key_base64: MII...==
  environment: sandbox
lemon_squeezy:
  api_key: xxxx
  store_id: yyyy
  signing_secret: aaaa
```

You can also nest these credentials under the Rails environment if using a shared credentials file.

```yaml
development:
  stripe:
    private_key: xxxx
# ...
```

##### Environment Variables

Pay will also check environment variables for API keys:

- `STRIPE_PUBLIC_KEY`
- `STRIPE_PRIVATE_KEY`
- `STRIPE_SIGNING_SECRET`
- `STRIPE_WEBHOOK_RECEIVE_TEST_EVENTS`
- `BRAINTREE_MERCHANT_ID`
- `BRAINTREE_PUBLIC_KEY`
- `BRAINTREE_PRIVATE_KEY`
- `BRAINTREE_ENVIRONMENT`
- `PADDLE_BILLING_API_KEY`
- `PADDLE_BILLING_CLIENT_TOKEN`
- `PADDLE_BILLING_SIGNING_SECRET`
- `PADDLE_BILLING_ENVIRONMENT`
- `PADDLE_CLASSIC_VENDOR_ID`
- `PADDLE_CLASSIC_VENDOR_AUTH_CODE`
- `PADDLE_CLASSIC_PUBLIC_KEY_BASE64`
- `PADDLE_CLASSIC_ENVIRONMENT`
- `LEMON_SQUEEZY_API_KEY`
- `LEMON_SQUEEZY_STORE_ID`
- `LEMON_SQUEEZY_SIGNING_SECRET`

## Configuration

You can configure Pay by creating a `config/initializers/pay.rb` file in your Rails application:

```ruby
Pay.setup do |config|
  # For use in the receipt/refund/renewal mailers
  config.business_name = "Business Name"
  config.business_address = "1600 Pennsylvania Avenue NW"
  config.application_name = "My App"
  config.support_email = "Business Name <support@example.com>"

  config.default_product_name = "default"
  config.default_plan_name = "default"

  config.automount_routes = true
  config.routes_path = "/pay" # Only when automount_routes is true

  # All processors are enabled by default. You can disable processors by removing them from the list.
  config.enabled_processors = [:stripe, :braintree, :paddle_billing, :paddle_classic, :lemon_squeezy]

  # To disable all emails, set the following configuration option to false:
  config.send_emails = true

  # All emails can be configured independently as to whether to be sent or not.
  # The values can be set to true, false or a custom lambda
  config.emails.payment_action_required = true
  config.emails.payment_failed = true
  config.emails.receipt = true
  config.emails.refund = true

  # Will only send the email if the subscription is renewing and it's a yearly subscription
  config.emails.subscription_renewing = ->(pay_subscription, price) {
    (price&.type == "recurring") && (price.recurring&.interval == "year")
  }

  config.emails.subscription_trial_will_end = true
  config.emails.subscription_trial_ended = true
end
```

### Business Configuration

These configuration options are used in the mailers Pay sends:

- `business_name` - Your business name
- `business_address` - Your business address
- `application_name` - Your application name
- `support_email` - Email address for support emails

### Email Configuration

Pay sends several types of emails to your customers:

- `payment_action_required` - When a payment requires additional action (like 3D Secure)
- `payment_failed` - When a payment fails
- `receipt` - When a payment is successful
- `refund` - When a refund is issued
- `subscription_renewing` - Before a subscription renews
- `subscription_trial_will_end` - Before a trial ends
- `subscription_trial_ended` - When a trial ends

You can disable all emails by setting `config.send_emails = false` or configure each email independently.

Each email can be configured with:
- `true` - Always send the email
- `false` - Never send the email
- A lambda - Custom logic to determine if the email should be sent

For example, to only send renewal emails for yearly subscriptions:

```ruby
config.emails.subscription_renewing = ->(pay_subscription, price) {
  (price&.type == "recurring") && (price.recurring&.interval == "year")
}
```

### Processor Configuration

All processors are enabled by default. You can configure which processors to use:

```ruby
config.enabled_processors = [:stripe, :braintree, :paddle_billing, :paddle_classic, :lemon_squeezy]
```

Remove any processors you don't want to use from this list.

### Route Configuration

Pay automatically mounts routes for webhooks. You can customize this behavior:

- `automount_routes` - Set to `false` to disable automatic route mounting
- `routes_path` - Customize the path where Pay routes are mounted (default: `/pay`)

### Default Names

Pay uses default names for products and plans when not specified:

- `default_product_name` - Default product name (default: "default")
- `default_plan_name` - Default plan name (default: "default")

## Customizing Views

Pay provides generators to customize the email views:

```bash
bin/rails generate pay:views
bin/rails generate pay:email_views
```

This will copy the view templates to your application where you can customize them.

## Background Jobs

Pay uses background jobs for processing webhooks and other tasks. It's recommended to configure a queue adapter in your application:

```ruby
# config/application.rb
config.active_job.queue_adapter = :sidekiq
```

Pay will use whatever queue adapter you have configured in your Rails application.

## Webhook Configuration

Pay automatically sets up webhook endpoints for each payment processor. The webhook URLs follow this pattern:

- Stripe: `/pay/webhooks/stripe`
- Braintree: `/pay/webhooks/braintree`
- Paddle Billing: `/pay/webhooks/paddle_billing`
- Paddle Classic: `/pay/webhooks/paddle_classic`
- Lemon Squeezy: `/pay/webhooks/lemon_squeezy`

You'll need to configure these webhook URLs in your payment processor's dashboard.

### Webhook Signing Secrets

For security, payment processors use signing secrets to verify webhook requests. Configure these in your Rails credentials:

**Stripe:**
```yaml
stripe:
  signing_secret:
    - whsec_xxxxx  # Your webhook signing secret
    - whsec_yyyyy  # You can have multiple secrets for key rotation
```

**Paddle Billing:**
```yaml
paddle_billing:
  signing_secret: pdl_ntfset_xxxxx
```

**Lemon Squeezy:**
```yaml
lemon_squeezy:
  signing_secret: your_signing_secret
```

### Testing Webhooks in Development

For Stripe, you can enable test event reception in development:

```yaml
stripe:
  webhook_receive_test_events: true
```

This allows you to receive test mode webhook events in your development environment.

## Additional Resources

For more information, see:
- [Pay GitHub Repository](https://github.com/pay-rails/pay)
- [Pay Documentation](https://github.com/pay-rails/pay/tree/main/docs)
- [Installation Guide](https://github.com/pay-rails/pay/blob/main/docs/1_installation.md)
- [Subscriptions Guide](https://github.com/pay-rails/pay/blob/main/docs/6_subscriptions.md)

---

**Note:** This documentation is based on the Pay gem configuration guide. For the most up-to-date information, always refer to the [official Pay documentation](https://github.com/pay-rails/pay/blob/main/docs/2_configuration.md).
