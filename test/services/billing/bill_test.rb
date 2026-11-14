require "test_helper"
require "support/fake_stripe"

class Billing::BillTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @account = accounts(:personal_account)
    @agents = @account.agents.order(:id).first(3)
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
  end

  def paid!(agent, price, status: "active")
    id = "sub_#{agent.id}"
    @stripe.put_subscription(id: id, agent: agent, customer: "cus_1", price: price, status: status)
    Billing::BillSync.new(id, client: @stripe).call
  end

  def plan!(price, status: "active")
    @stripe.put_account_subscription(id: "sub_a", account: @account, customer: "cus_1", price: price, status: status)
    Billing::BillSync.new("sub_a", client: @stripe).call
  end

  def bill = Billing::Bill.new(@account)

  test "an account that pays for nothing has an empty bill of nothing" do
    assert_empty bill.lines
    assert_empty bill.items
    assert bill.empty?
    assert_equal BigDecimal("0"), bill.total_usd
  end

  test "two residents sold at the same price are one line of two" do
    paid!(@agents[0], CONVERSATION_PRICE)
    paid!(@agents[1], CONVERSATION_PRICE)

    line = bill.lines.sole
    assert_equal [ "resident", "conversation", "Small", CONVERSATION_PRICE, 2 ],
      [ line.kind, line.id, line.name, line.price_id, line.quantity ]
    assert_equal BigDecimal("9.99"), line.unit_usd
    assert_equal BigDecimal("19.98"), bill.total_usd
    assert_equal [ { price: CONVERSATION_PRICE, quantity: 2 } ], bill.items
  end

  test "the plan comes first, then residents small to large, standard before at cost" do
    paid!(@agents[0], WORK_PRICE)
    paid!(@agents[1], CONVERSATION_AT_COST_PRICE)
    paid!(@agents[2], CONVERSATION_PRICE)
    plan!(PARTNERS_PRICE)

    assert_equal [ PARTNERS_PRICE, CONVERSATION_PRICE, CONVERSATION_AT_COST_PRICE, WORK_PRICE ], bill.lines.map(&:price_id)
    assert_equal %w[plan resident resident resident], bill.lines.map(&:kind)
    assert_equal [ "Partners", "Small", "Small at cost", "Large" ], bill.lines.map(&:name)
    assert_equal BigDecimal("20") + BigDecimal("9.99") + BigDecimal("8") + BigDecimal("69.99"), bill.total_usd
    assert_equal "107.98", bill.as_json[:total_usd]
  end

  test "a resident on a retired price keeps it, on its own line, with no amount the house would have to guess" do
    saved = ENV["STRIPE_PRICE_LIFE_AT_COST"]
    ENV["STRIPE_PRICE_LIFE_AT_COST"] = "price_life_at_cost_new,#{LIFE_AT_COST_PRICE}"
    paid!(@agents[0], LIFE_AT_COST_PRICE)
    paid!(@agents[1], LIFE_AT_COST_PRICE)

    line = bill.lines.sole
    assert_equal [ LIFE_AT_COST_PRICE, 2 ], [ line.price_id, line.quantity ]
    assert_nil line.unit_usd
    assert_nil bill.total_usd
    assert_equal [ { price: LIFE_AT_COST_PRICE, quantity: 2 } ], bill.items
  ensure
    ENV["STRIPE_PRICE_LIFE_AT_COST"] = saved
  end

  test "the bill follows the charge: an ended subscription is off it, a past-due one is on it, even after grace ran out" do
    paid!(@agents[0], CONVERSATION_PRICE)
    paid!(@agents[1], LIFE_PRICE)
    paid!(@agents[0], CONVERSATION_PRICE, status: "canceled")
    paid!(@agents[1], LIFE_PRICE, status: "past_due")
    assert_equal [ { price: LIFE_PRICE, quantity: 1 } ], bill.items

    entitlement = ResidentEntitlement.find_by!(agent: @agents[1])
    travel_to entitlement.grace_deadline + 1.minute do
      assert entitlement.expire_grace!
      assert_not ResidentEntitlement.paid_for?(@agents[1]), "held: its grace ran out"
      assert_equal [ { price: LIFE_PRICE, quantity: 1 } ], bill.items, "Stripe is still asking for it"
    end
  end

  test "an account plan is on the bill while its subscription lives, past due included, and off it once ended" do
    plan!(COLLEAGUES_PRICE)
    assert_equal [ { price: COLLEAGUES_PRICE, quantity: 1 } ], bill.items
    plan!(COLLEAGUES_PRICE, status: "past_due")
    travel_to 1.month.from_now do
      assert_equal "companions", @account.reload.plan.id, "out of force after grace"
      assert_equal [ { price: COLLEAGUES_PRICE, quantity: 1 } ], bill.items
    end
    plan!(COLLEAGUES_PRICE, status: "canceled")
    assert_empty bill.items
  end

  test "a missing or unknown recorded price is refused, for a resident and for the plan, never billed as something else" do
    paid!(@agents[0], CONVERSATION_PRICE)
    row = ResidentSubscription.find_by!(agent: @agents[0])
    row.update_columns(stripe_price_id: "price_from_nowhere")
    assert_match(/price_from_nowhere/, assert_raises(Billing::Bill::UnknownPrice) { bill.lines }.message)
    row.update_columns(stripe_price_id: nil)
    assert_match(/nil/, assert_raises(Billing::Bill::UnknownPrice) { bill.lines }.message)
    row.update_columns(stripe_price_id: LIFE_PRICE)
    assert_raises(Billing::Bill::UnknownPrice, "another offer's price is not this row's") { bill.lines }
    row.update_columns(stripe_price_id: CONVERSATION_PRICE)

    plan!(PARTNERS_PRICE)
    plan = AccountSubscription.find_by!(account: @account)
    plan.update_columns(stripe_price_id: nil)
    assert_raises(Billing::Bill::UnknownPrice) { bill.lines }
    plan.update_columns(stripe_price_id: COLLEAGUES_PRICE)
    assert_raises(Billing::Bill::UnknownPrice) { bill.lines }
  end

end
