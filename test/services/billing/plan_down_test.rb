require "test_helper"
require "support/fake_stripe"

# Lowering Partners or Colleagues is a move on the Billing tab
# (Accounts::BillingsController#account_plan_change, a "plan" op): the bill
# then asks for the smaller plan, its included resident unchanged. Ending a
# plan altogether is ending its last resident, which ends the bill at the
# period's end (plan_includes_resident_test). Build C slice 3 checks both
# before changing any copy.
class Billing::PlanDownTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  PRICES = {
    COMPANIONS_PRICE => 999, PARTNERS_PRICE => 2999, COLLEAGUES_PRICE => 5999,
    CONVERSATION_PRICE => 999, LIFE_PRICE => 3999, WORK_PRICE => 6999,
    CONVERSATION_INCLUDED_PRICE => 0, LIFE_INCLUDED_PRICE => 3000, WORK_INCLUDED_PRICE => 6000
  }.freeze

  setup do
    Setting.instance.update!(allow_agents: true)
    @account = accounts(:personal_account)
    @account.update!(billing_required: true)
    @owner = users(:user_1)
    @stripe = FakeStripe.new
    CATALOGUE.each { |id, (product, _)| @stripe.put_price(id, product:, unit_amount: PRICES.fetch(id, CATALOGUE[id][1])) }
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_payment_method("pm_visa")
    @stripe.put_customer("cus_1", default_payment_method: "pm_visa")
  end

  def paid_birth = Billing::PaidBirth.new(client: @stripe)
  def reconcile = Billing::Reconcile.new(account: @account, client: @stripe)
  def go!(ops) = reconcile.propose(ops).then { |change| reconcile.confirm(change, digest: change.digest) }

  def first_bill!(tier)
    order, = paid_birth.start!(account: @account, creator: @owner, open_beginning: true, tier: Billing::Tier.find!(tier),
      attributes: { name: "Aria", system_prompt: "", model_id: "openrouter/auto" })
    sub = @stripe.subscriptions.retrieve(order.stripe_subscription_id)
    @stripe.set_subscription_status(sub.id, "active") unless sub.status == "active"
    paid_birth.complete!(order)
    sub.id
  end

  def monthly(id) = Billing::BillSync.remote_lines(@stripe.subscriptions.retrieve(id), client: @stripe)
    .sum { |price, quantity| PRICES.fetch(price) * quantity }

  %w[partners colleagues].each do |from|
    test "#{from.capitalize} moves down to Companions on the bill, its Small still included" do
      @account.update!(chosen_plan: from)
      sub = first_bill!("conversation")
      assert_equal from, @account.reload.plan.id
      go!([ { op: "plan", price: COMPANIONS_PRICE } ])
      assert_equal 999, monthly(sub)
      assert_equal({ COMPANIONS_PRICE => 1, CONVERSATION_INCLUDED_PRICE => 1 }, Billing::BillSync.house_lines(sub))
      assert_equal "companions", @account.reload.plan.id
    end
  end

  test "Colleagues moves down to Partners" do
    @account.update!(chosen_plan: "colleagues")
    sub = first_bill!("conversation")
    go!([ { op: "plan", price: PARTNERS_PRICE } ])
    assert_equal 2999, monthly(sub)
  end

  test "a plan can't be dropped from a bill while its included resident is on it: ending it is ending the resident" do
    @account.update!(chosen_plan: "partners")
    sub = first_bill!("conversation")
    error = assert_raises(Billing::Reconcile::Refused) { reconcile.propose([ { op: "plan", price: nil } ]) }
    assert_match(/plan stays while its included resident is on the bill/, error.message)
    change = reconcile.propose_end(@account.agents.find_by!(name: "Aria"))
    reconcile.confirm(change, digest: change.digest)
    assert @stripe.subscriptions.retrieve(sub).cancel_at_period_end
  end

end
