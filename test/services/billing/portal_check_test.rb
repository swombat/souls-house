require "test_helper"
require "support/fake_stripe"

class Billing::PortalCheckTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @stripe = FakeStripe.new
    @now = Time.zone.parse("2026-10-28 17:00")
  end

  def check = Billing::PortalCheck.new(client: @stripe).read(@now)

  test "a portal that lets nobody switch plans reports nothing switchable" do
    @stripe.put_portal_configuration(prices: [])
    assert_equal({ checked_at: @now.iso8601, switchable_prices: [], at_cost_switchable: [] }, check)
  end

  test "standard prices in the portal's switcher are listed; an at-cost price among them is called out" do
    @stripe.put_portal_configuration(prices: [ CONVERSATION_PRICE, LIFE_PRICE ])
    result = check
    assert_equal [ CONVERSATION_PRICE, LIFE_PRICE ], result[:switchable_prices]
    assert_empty result[:at_cost_switchable]

    @stripe.put_portal_configuration(prices: [ LIFE_AT_COST_PRICE ])
    result = check
    assert_equal [ CONVERSATION_PRICE, LIFE_PRICE, LIFE_AT_COST_PRICE ], result[:switchable_prices]
    assert_equal [ LIFE_AT_COST_PRICE ], result[:at_cost_switchable]
  end

  test "inactive configurations and switched-off switchers don't count" do
    @stripe.put_portal_configuration(prices: [ WORK_AT_COST_PRICE ], active: false)
    @stripe.put_portal_configuration(prices: [ WORK_AT_COST_PRICE ], enabled: false)
    assert_empty check[:switchable_prices]
  end

  test "a Stripe error is an error, not an empty answer" do
    failing = Struct.new(:v1).new(Struct.new(:billing_portal).new(Struct.new(:configurations).new(
      Class.new { def list(_params) = raise(Stripe::APIConnectionError.new("no route to Stripe")) }.new
    )))
    result = Billing::PortalCheck.new(client: failing).read(@now)
    assert_equal "no route to Stripe", result[:error]
    assert_nil result[:switchable_prices]
  end

end
