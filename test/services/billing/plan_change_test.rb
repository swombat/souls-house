require "test_helper"
require "support/fake_stripe"

class Billing::PlanChangeTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @agent = agents(:research_assistant)
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @agent.account, stripe_customer_id: "cus_1")
    @now = Time.utc(2026, 10, 11, 12)
    travel_to @now
  end

  def paid!(price)
    @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1", price: price, status: "active")
    Billing::SubscriptionSync.new("sub_1", client: @stripe).call
  end

  def change!(tier) = Billing::PlanChange.new(agent: @agent, tier: Billing::Tier.find!(tier), client: @stripe).call

  test "moves the subscription's item to the other plan's current price, prorated, and the house follows at once" do
    paid!(CONVERSATION_PRICE)
    entitlement = ResidentEntitlement.find_by!(agent: @agent)
    assert_equal BigDecimal("10"), entitlement.allowance_limit

    subscription = change!("life")

    id, params = @stripe.subscription_updates.sole
    assert_equal "sub_1", id
    assert_equal [ { id: "si_sub_1", price: LIFE_PRICE } ], params[:items]
    assert_equal "create_prorations", params[:proration_behavior]
    assert_equal "Life hosting for #{@agent.name}", params[:description]
    assert_equal "life", subscription.tier
    assert_equal "standard", subscription.rate
    assert_equal LIFE_PRICE, subscription.stripe_price_id
    assert_equal "life", entitlement.reload.tier
    assert_equal BigDecimal("25"), entitlement.allowance_limit

    change!("conversation")
    assert_equal "conversation", entitlement.reload.tier
    assert_equal BigDecimal("25"), entitlement.allowance_limit, "the month keeps its high-water mark"
  end

  test "the rate stays what it was: an at-cost plan moves to the other plan's at-cost price" do
    paid!(CONVERSATION_AT_COST_PRICE)
    subscription = change!("work")
    assert_equal [ { id: "si_sub_1", price: WORK_AT_COST_PRICE } ], @stripe.subscription_updates.sole[1][:items]
    assert_equal "at_cost", subscription.rate
    assert_equal "work", subscription.tier
    assert_equal BigDecimal("0"), ResidentEntitlement.find_by!(agent: @agent).allowance_limit
  end

  test "nothing to change without a paid plan, and nothing to do on the same plan" do
    error = assert_raises(Billing::PlanChange::Refused) { change!("life") }
    assert_match(/no paid plan/, error.message)

    paid!(LIFE_PRICE)
    error = assert_raises(Billing::PlanChange::Refused) { change!("life") }
    assert_match(/already on Life/, error.message)
    assert_empty @stripe.subscription_updates
  end

  # Mira's finding on #628: a key per (from, to) would make A->B->A->B replay
  # the first change instead of performing the last.
  test "every change has a key of its own, so going back and forth performs each change" do
    paid!(CONVERSATION_PRICE)
    change!("life")
    change!("conversation")
    change!("life")
    change!("conversation")

    keys = @stripe.subscription_updates.map { |_id, _params, opts| opts[:idempotency_key] }
    assert_equal 4, keys.size
    assert_equal 4, keys.uniq.size
    assert_equal %w[1 2 3 4], keys.map { |key| key[/-sub_1-(\d+)-/, 1] }
    assert_equal "conversation", ResidentEntitlement.find_by!(agent: @agent).tier
    assert_equal 4, ResidentSubscription.find_by!(stripe_subscription_id: "sub_1").plan_changes_count
  end

  test "a change Stripe refused before performing it leaves its identity behind; the retry is a change of its own" do
    paid!(CONVERSATION_PRICE)
    @stripe.fail_next_subscription_update(Stripe::APIConnectionError.new("timed out"))
    assert_raises(Stripe::APIConnectionError) { change!("life") }
    assert_equal 1, ResidentSubscription.find_by!(stripe_subscription_id: "sub_1").plan_changes_count,
      "the identity was committed before Stripe was called"

    change!("life")
    _id, _params, opts = @stripe.subscription_updates.sole
    assert_equal "souls-house-plan-change-sub_1-2-#{CONVERSATION_PRICE}-#{LIFE_PRICE}", opts[:idempotency_key]
    assert_equal "life", ResidentEntitlement.find_by!(agent: @agent).tier
  end

  # Mira's finding on #628: a change Stripe performed whose local sync then
  # failed must not leave a key the next change would reuse and be replayed
  # under, unperformed.
  test "a change Stripe performed but the house failed to record is brought in, and the next change is performed, not replayed" do
    paid!(CONVERSATION_PRICE)
    stripe = @stripe
    failing_after_update = Class.new(Billing::SubscriptionSync) do
      define_method(:call) do
        last = stripe.subscription_updates.last
        raise ActiveRecord::StatementInvalid, "connection lost" if last && !last[2][:replayed] && !stripe.instance_variable_get(:@recovered)
        super()
      end
    end
    service = Billing::PlanChange.new(agent: @agent, tier: Billing::Tier.find!("life"), client: @stripe)
    service.define_singleton_method(:sync_class) { failing_after_update }
    assert_raises(ActiveRecord::StatementInvalid) { service.call }
    assert_equal LIFE_PRICE, @stripe.subscription("sub_1")[:items][:data].first[:price][:id], "Stripe performed the change"
    assert_equal "conversation", ResidentEntitlement.find_by!(agent: @agent).tier, "the house did not record it"
    assert_equal 1, ResidentSubscription.find_by!(stripe_subscription_id: "sub_1").plan_changes_count

    # The next change brings Stripe's state in first, then is a change of its own.
    @stripe.instance_variable_set(:@recovered, true)
    change!("conversation")
    keys = @stripe.subscription_updates.map { |_id, _params, opts| opts[:idempotency_key] }
    assert_equal %w[1 2], keys.map { |key| key[/-sub_1-(\d+)-/, 1] }
    assert_equal CONVERSATION_PRICE, @stripe.subscription("sub_1")[:items][:data].first[:price][:id]
    assert_equal "conversation", ResidentEntitlement.find_by!(agent: @agent).tier
    assert_not @stripe.subscription_updates.last[2][:replayed], "performed, not replayed"
  end

  # Mira's last finding on #628: retrying the same change after Stripe
  # performed it and the house failed to record it must leave the house
  # reconciled, not roll the reconciliation back with the "already on" refusal.
  test "retrying a change Stripe already performed reconciles the house and updates Stripe no further" do
    paid!(CONVERSATION_PRICE)
    stripe = @stripe
    failing_after_update = Class.new(Billing::SubscriptionSync) do
      define_method(:call) do
        last = stripe.subscription_updates.last
        raise ActiveRecord::StatementInvalid, "connection lost" if last && !stripe.instance_variable_get(:@recovered)
        super()
      end
    end
    service = Billing::PlanChange.new(agent: @agent, tier: Billing::Tier.find!("life"), client: @stripe)
    service.define_singleton_method(:sync_class) { failing_after_update }
    assert_raises(ActiveRecord::StatementInvalid) { service.call }
    assert_equal "conversation", ResidentEntitlement.find_by!(agent: @agent).tier, "the house did not record it"

    @stripe.instance_variable_set(:@recovered, true)
    error = assert_raises(Billing::PlanChange::Refused) { change!("life") }
    assert_match(/already on Life/, error.message)
    entitlement = ResidentEntitlement.find_by!(agent: @agent)
    assert_equal "life", entitlement.tier, "the reconciliation stands"
    assert_equal BigDecimal("25"), entitlement.allowance_limit
    assert_equal 1, @stripe.subscription_updates.size, "Stripe was not updated again"
  end

  test "a replayed key performs nothing: the fake, like Stripe, returns the cached answer" do
    paid!(CONVERSATION_PRICE)
    @stripe.v1.subscriptions.update("sub_1", { items: [ { id: "si_sub_1", price: LIFE_PRICE } ] }, { idempotency_key: "k" })
    @stripe.v1.subscriptions.update("sub_1", { items: [ { id: "si_sub_1", price: WORK_PRICE } ] }, { idempotency_key: "k" })
    assert_equal LIFE_PRICE, @stripe.subscription("sub_1")[:items][:data].first[:price][:id]
    assert @stripe.subscription_updates.last[2][:replayed]
  end

end
