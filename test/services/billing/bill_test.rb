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
    Billing::SubscriptionSync.new(id, client: @stripe).call
  end

  def plan!(price, status: "active")
    @stripe.put_account_subscription(id: "sub_a", account: @account, customer: "cus_1", price: price, status: status)
    Billing::SubscriptionSync.new("sub_a", client: @stripe).call
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

  test "a resident whose plan has ended is off the bill; one in grace is still on it" do
    paid!(@agents[0], CONVERSATION_PRICE)
    paid!(@agents[1], LIFE_PRICE)
    paid!(@agents[0], CONVERSATION_PRICE, status: "canceled")
    paid!(@agents[1], LIFE_PRICE, status: "past_due")

    assert_equal [ { price: LIFE_PRICE, quantity: 1 } ], bill.items
  end

  test "an ended account plan is off the bill" do
    plan!(COLLEAGUES_PRICE)
    assert_equal [ { price: COLLEAGUES_PRICE, quantity: 1 } ], bill.items
    plan!(COLLEAGUES_PRICE, status: "canceled")
    assert_empty bill.items
  end

  test "a recorded price that is not one of the offer's is refused, never billed as something else" do
    paid!(@agents[0], CONVERSATION_PRICE)
    ResidentSubscription.find_by!(agent: @agents[0]).update_columns(stripe_price_id: "price_from_nowhere")

    error = assert_raises(Billing::Bill::UnknownPrice) { bill.lines }
    assert_match(/price_from_nowhere/, error.message)
  end

end
