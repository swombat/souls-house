# Paid hosting through Stripe (docs/proposals/2026-10-07-stripe-billing.md).
# Keys live in credentials per environment; ENV is the fallback for local runs.
# Test mode until Daniel switches the keys.
module Billing

  class NotConfigured < StandardError; end
  class InvalidSubscription < StandardError; end
  class AlreadySubscribed < StandardError; end

  GRACE_PERIOD = 14.days

  def self.secret_key
    Rails.application.credentials.dig(:stripe, :secret_key).presence || ENV["STRIPE_SECRET_KEY"].presence
  end

  def self.webhook_secret
    Rails.application.credentials.dig(:stripe, :webhook_secret).presence || ENV["STRIPE_WEBHOOK_SECRET"].presence
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

  def self.test_mode?
    secret_key.to_s.start_with?("sk_test_", "rk_test_")
  end

  def self.client
    raise NotConfigured, "Stripe is not configured on this house" if secret_key.blank?

    Stripe::StripeClient.new(secret_key)
  end

end
