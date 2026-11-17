require "test_helper"
require "support/fake_stripe"

# A withdrawn plan grant leaves the account paying for its plan, with the
# resident it includes still at $0: the model in plan_includes_resident_test
# with the grant gone. Before, the bill kept a $0 resident and no plan line.
class Billing::PlanAfterGrantTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  PRICES = {
    COMPANIONS_PRICE => 999, PARTNERS_PRICE => 2999, COLLEAGUES_PRICE => 5999,
    CONVERSATION_PRICE => 999, LIFE_PRICE => 3999, WORK_PRICE => 6999,
    CONVERSATION_INCLUDED_PRICE => 0, LIFE_INCLUDED_PRICE => 3000, WORK_INCLUDED_PRICE => 6000,
    LIFE_AT_COST_HETZNER_PRICE => 1100, WORK_AT_COST_HETZNER_PRICE => 2000
  }.freeze

  setup do
    Setting.instance.update!(allow_agents: true)
    @account = accounts(:personal_account)
    @account.update!(billing_required: true)
    @owner = users(:user_1)
    @admin = users(:site_admin_user)
    @stripe = FakeStripe.new
    CATALOGUE.each { |id, (product, _)| @stripe.put_price(id, product:, unit_amount: PRICES.fetch(id, CATALOGUE[id][1])) }
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_payment_method("pm_visa")
    @stripe.put_customer("cus_1", default_payment_method: "pm_visa")
  end

  def paid_birth = Billing::PaidBirth.new(client: @stripe)

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

  def redeem!(effect)
    BillingCode.create!(code: "GRANT-#{effect.tr(':', '-').upcase}", effect:, created_by: @admin)
    BillingCode.redeem!(code: "GRANT-#{effect.tr(':', '-').upcase}", account: @account, by: @owner)
  end

  test "withdrawing a plan code puts Companions back on the bill: $9.99, its Small still included at $0" do
    redemption = redeem!("plan:companions")
    sub = first_bill!("conversation")
    assert_equal 0, monthly(sub), "while the grant stands, the account is free"
    assert_nil Billing::PlanAfterGrant.restore!(@account, by: @admin, client: @stripe), "nothing to put back while it stands"

    redemption.withdraw!(by: @admin)
    change = Billing::PlanAfterGrant.restore!(@account, by: @admin, client: @stripe)
    assert change&.applied?
    assert_equal 999, monthly(sub)
    assert_equal({ COMPANIONS_PRICE => 1, CONVERSATION_INCLUDED_PRICE => 1 }, Billing::BillSync.house_lines(sub))
    assert_nil Billing::PlanAfterGrant.restore!(@account, by: @admin, client: @stripe), "once is all: the plan is paid for now"
  end

  test "the plan chosen before the grant is the one paid for after it, with a bigger included resident's difference" do
    @account.update!(chosen_plan: "partners")
    redemption = redeem!("plan:colleagues")
    sub = first_bill!("life")
    assert_equal 3000, monthly(sub)
    redemption.withdraw!(by: @admin)
    Billing::PlanAfterGrant.restore!(@account, by: @admin, client: @stripe)
    assert_equal 2999 + 3000, monthly(sub)
  end

  test "an account still given a plan by another grant keeps it free" do
    first = redeem!("plan:companions")
    redeem!("plan:partners")
    sub = first_bill!("conversation")
    first.withdraw!(by: @admin)
    assert_nil Billing::PlanAfterGrant.restore!(@account, by: @admin, client: @stripe)
    assert_equal 0, monthly(sub)
  end

  test "a plan never bought alone: with no included resident on the bill the plan op is still refused" do
    rows = { agents(:research_assistant) => CONVERSATION_PRICE }
    @stripe.put_shared_subscription(id: "sub_old", account: @account, customer: "cus_1", status: "active",
      items: rows.map { |agent, price| { agent:, price: } })
    seed_bill!("sub_old")
    reconcile = Billing::Reconcile.new(account: @account, client: @stripe)
    error = assert_raises(Billing::Reconcile::Refused) { reconcile.propose([ { op: "plan", price: COMPANIONS_PRICE } ]) }
    assert_match(/bought with the resident it includes/, error.message)
    assert_nil Billing::PlanAfterGrant.restore!(@account, by: @admin, client: @stripe)
  end

end
