require "test_helper"
require "support/fake_stripe"

# The Billing card on Site Settings: what used to reach only Honeybadger.
class Admin::BillingStatusTest < ActionDispatch::IntegrationTest

  include FakeStripe::Helpers

  setup do
    @stripe = FakeStripe.new
    sign_in users(:site_admin_user)
  end

  test "failed Stripe events, ungranted at-cost subscriptions and the portal's switchable prices are shown" do
    StripeEvent.create!(stripe_event_id: "evt_old", event_type: "customer.subscription.updated", status: "failed",
      last_error: "Billing::InvalidSubscription: old one", attempts: 1, updated_at: 10.days.ago)
    StripeEvent.create!(stripe_event_id: "evt_1", event_type: "customer.subscription.updated", status: "failed",
      last_error: "Billing::InvalidSubscription: Subscription sub_x has a price outside the plan catalogue", attempts: 1)
    StripeEvent.create!(stripe_event_id: "evt_2", event_type: "invoice.paid", status: "processed", attempts: 1)
    AuditLog.create!(account: accounts(:personal_account), action: "billing_rate_without_grant",
      data: { "stripe_subscription_id" => "sub_x", "rate" => "at_cost" })
    # A second sync of the same subscription writes a second row; it is one subscription.
    AuditLog.create!(account: accounts(:personal_account), action: "billing_rate_without_grant",
      data: { "stripe_subscription_id" => "sub_x", "rate" => "at_cost" })
    @stripe.put_portal_configuration(prices: [ LIFE_AT_COST_PRICE ])

    Billing.stub(:client, @stripe) do
      get admin_settings_path
    end

    assert_response :success
    billing = inertia_shared_props["billing"]
    assert billing["configured"]
    assert_equal 1, billing["stripe_events_failed"], "only the last 7 days"
    assert_match(/outside the plan catalogue/, billing["stripe_events_last_error"])
    assert_equal 1, billing["ungranted_subscriptions"]
    assert_equal [ LIFE_AT_COST_PRICE ], billing.dig("portal", "at_cost_switchable")
    assert_equal [ LIFE_AT_COST_PRICE ], billing.dig("portal", "switchable_prices")
  end

  test "with nothing wrong the card says so, and the portal lets nobody switch" do
    Billing.stub(:client, @stripe) do
      get admin_settings_path
    end

    billing = inertia_shared_props["billing"]
    assert_equal 0, billing["stripe_events_failed"]
    assert_nil billing["stripe_events_last_error"]
    assert_equal 0, billing["ungranted_subscriptions"]
    assert_equal [], billing.dig("portal", "switchable_prices")
    assert_equal [], billing.dig("portal", "at_cost_switchable")
  end

end
