# Paid hosting through Stripe (docs/proposals/2026-10-07-stripe-billing.md).
# Keys live in credentials per environment; ENV is the fallback for local runs.
# Test mode until Daniel switches the keys.
module Billing

  class NotConfigured < StandardError; end
  class InvalidSubscription < StandardError; end
  class AlreadySubscribed < StandardError; end
  class NotReady < StandardError; end
  # A rate the account holds no grant for (see Account#eligible_rates).
  class NotEligible < StandardError; end
  # Reported, never raised to a caller: a paid at-cost subscription on an
  # account with no grant and no redemption named on the purchase.
  class UngrantedRate < StandardError; end

  GRACE_PERIOD = 14.days
  # Upgrade the SDK independently of Stripe's billing request contract.
  # This is the version used by stripe-ruby 20.0.0; changing it needs a
  # separate billing compatibility review.
  STRIPE_API_VERSION = "2026-09-30.endive"

  def self.secret_key
    Rails.application.credentials.dig(:stripe, :secret_key).presence || ENV["STRIPE_SECRET_KEY"].presence
  end

  def self.webhook_secret
    Rails.application.credentials.dig(:stripe, :webhook_secret).presence || ENV["STRIPE_WEBHOOK_SECRET"].presence
  end

  # Public by design: Stripe.js needs it in the browser to mount Stripe's own
  # card form.
  def self.publishable_key
    Rails.application.credentials.dig(:stripe, :publishable_key).presence || ENV["STRIPE_PUBLISHABLE_KEY"].presence
  end

  def self.configured?
    secret_key.present? && Tier.all.any?(&:purchasable?)
  end

  # Where refund requests under the 30-day guarantee go: the house's own mail address.
  # ApplicationMailer first: it loads the mail gem, which a lazily loaded app
  # (development) hasn't done yet when a public page asks.
  def self.contact_email
    from = ApplicationMailer.default[:from]
    ::Mail::Address.new(from).address
  end

  # Money in JSON and copy: a two-place decimal string, "9.99", "20.00".
  def self.usd(amount) = format("%.2f", BigDecimal(amount.to_s))

  # Money in prose: "$9.99", "$20".
  def self.usd_label(amount)
    "$#{ActiveSupport::NumberHelper.number_to_rounded(BigDecimal(amount.to_s), precision: 2, strip_insignificant_zeros: true)}"
  end

  def self.test_mode?
    secret_key.to_s.start_with?("sk_test_", "rk_test_")
  end

  def self.client
    raise NotConfigured, "Stripe is not configured on this house" if secret_key.blank?

    Stripe::StripeClient.new(secret_key, stripe_version: STRIPE_API_VERSION)
  end

end
