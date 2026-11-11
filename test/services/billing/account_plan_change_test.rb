require "test_helper"
require "support/fake_stripe"

class Billing::AccountPlanChangeTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @account = accounts(:personal_account)
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
  end

  def paid!(price, status: "active")
    @stripe.put_account_subscription(id: "sub_a", account: @account, customer: "cus_1", price: price, status: status)
    Billing::SubscriptionSync.new("sub_a", client: @stripe).call
  end

  def change!(plan) = Billing::AccountPlanChange.new(account: @account, plan: Billing::AccountPlan.find!(plan), client: @stripe).call

  test "moves the item to the other plan's current price, prorated, and the account follows at once" do
    paid!(PARTNERS_PRICE)
    subscription = change!("colleagues")

    id, params, opts = @stripe.subscription_updates.sole
    assert_equal "sub_a", id
    assert_equal [ { id: "si_sub_a", price: COLLEAGUES_PRICE } ], params[:items]
    assert_equal "create_prorations", params[:proration_behavior]
    assert_equal({ plan: "colleagues" }, params[:metadata])
    assert_match(/\Asouls-house-account-plan-change-sub_a-1-#{PARTNERS_PRICE}-#{COLLEAGUES_PRICE}\z/, opts[:idempotency_key])
    assert_equal "colleagues", subscription.plan
    assert_equal "colleagues", @account.reload.plan.id

    change!("partners")
    assert_equal "partners", @account.reload.plan.id
  end

  test "nothing to change without a paid plan; nothing to do on the same plan; Companions is a cancellation" do
    error = assert_raises(Billing::AccountPlanChange::Refused) { change!("colleagues") }
    assert_match(/no paid plan/, error.message)

    paid!(PARTNERS_PRICE, status: "incomplete")
    assert_raises(Billing::AccountPlanChange::Refused) { change!("colleagues") }

    paid!(PARTNERS_PRICE)
    error = assert_raises(Billing::AccountPlanChange::Refused) { change!("partners") }
    assert_match(/already on Partners/, error.message)
    error = assert_raises(Billing::AccountPlanChange::Refused) { change!("companions") }
    assert_match(/Manage billing/, error.message)
    assert_empty @stripe.subscription_updates
  end

  test "every change has a key of its own, so going back and forth performs each change" do
    paid!(PARTNERS_PRICE)
    change!("colleagues")
    change!("partners")
    change!("colleagues")

    keys = @stripe.subscription_updates.map { |_id, _params, opts| opts[:idempotency_key] }
    assert_equal 3, keys.uniq.size
    assert_equal %w[1 2 3], keys.map { |key| key[/-sub_a-(\d+)-/, 1] }
    assert_equal 3, AccountSubscription.sole.plan_changes_count
  end

  test "retrying a change Stripe already performed reconciles the account and updates Stripe no further" do
    paid!(PARTNERS_PRICE)
    stripe = @stripe
    failing_after_update = Class.new(Billing::AccountSubscriptionSync) do
      define_method(:call) do
        raise ActiveRecord::StatementInvalid, "connection lost" if stripe.subscription_updates.any? && !stripe.instance_variable_get(:@recovered)

        super()
      end
    end
    service = Billing::AccountPlanChange.new(account: @account, plan: Billing::AccountPlan.find!("colleagues"), client: @stripe)
    service.define_singleton_method(:sync_class) { failing_after_update }
    assert_raises(ActiveRecord::StatementInvalid) { service.call }
    assert_equal "partners", @account.reload.plan.id, "the house did not record it"

    @stripe.instance_variable_set(:@recovered, true)
    error = assert_raises(Billing::AccountPlanChange::Refused) { change!("colleagues") }
    assert_match(/already on Colleagues/, error.message)
    assert_equal "colleagues", @account.reload.plan.id, "the reconciliation stands"
    assert_equal 1, @stripe.subscription_updates.size
  end

end
