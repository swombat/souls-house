require "test_helper"
require "support/fake_stripe"

# The plan includes its resident, at the advertised amounts (Daniel, jaMWBj
# jRyMoO/ebamzw 2026-11-13, ePoEyY JygPKB 2026-11-14): Companions $9.99,
# Partners $29.99, Colleagues $59.99, each with one Small included; a bigger
# included resident is the difference; each further resident is its size.
# Every amount below is the one /pricing states, set on the fake as the live
# Stripe prices are, and read back from what the house sends Stripe.
class Billing::PlanIncludesResidentTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  ADVERTISED = {
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
    @stripe = FakeStripe.new
    CATALOGUE.each { |id, (product, _)| @stripe.put_price(id, product:, unit_amount: ADVERTISED.fetch(id, CATALOGUE[id][1])) }
    BillingCustomer.create!(account: @account, stripe_customer_id: "cus_1")
    @stripe.put_payment_method("pm_visa")
    @stripe.put_customer("cus_1", default_payment_method: "pm_visa")
  end

  def paid_birth = Billing::PaidBirth.new(client: @stripe)
  def reconcile = Billing::Reconcile.new(account: @account, client: @stripe)
  def go!(ops) = reconcile.propose(ops).then { |change| reconcile.confirm(change, digest: change.digest) }

  # A first bill opened by creating a resident, paid and brought in.
  def first_bill!(tier, name: "Aria")
    order, = paid_birth.start!(account: @account, creator: @owner, open_beginning: true, tier: Billing::Tier.find!(tier),
      attributes: { name:, system_prompt: "", model_id: "openrouter/auto" })
    sub = @stripe.subscriptions.retrieve(order.stripe_subscription_id)
    @stripe.set_subscription_status(sub.id, "active") unless sub.status == "active"
    paid_birth.complete!(order)
    [ order.reload, sub.id ]
  end

  # What a subscription asks for each month, from its lines at Stripe's prices.
  def monthly(id) = Billing::BillSync.remote_lines(@stripe.subscriptions.retrieve(id), client: @stripe)
    .sum { |price, quantity| ADVERTISED.fetch(price) * quantity }

  def agent(name) = @account.agents.find_by!(name:)

  test "a first Small on Companions is $9.99: the plan, its resident included at $0" do
    _, sub = first_bill!("conversation")
    assert_equal 999, monthly(sub)
    assert_equal({ COMPANIONS_PRICE => 1, CONVERSATION_INCLUDED_PRICE => 1 }, Billing::BillSync.house_lines(sub))
  end

  test "Partners with a Medium as its included resident is $59.99" do
    @account.update!(chosen_plan: "partners")
    _, sub = first_bill!("life")
    assert_equal 2999 + 3000, monthly(sub)
    assert_equal "partners", @account.reload.plan.id
  end

  test "Colleagues with a Large as its included resident is $119.99" do
    @account.update!(chosen_plan: "colleagues")
    _, sub = first_bill!("work")
    assert_equal 5999 + 6000, monthly(sub)
  end

  test "a second Small adds $9.99; the included one ending promotes it to $0; the last one ending ends the bill" do
    _, sub = first_bill!("conversation", name: "Aria")
    assert_equal 999, monthly(sub)
    second = @account.agents.where.not(id: agent("Aria").id).first
    go!(Billing::Reconcile.add_ops(@account, second, Billing::Tier.find!("conversation").offer, client: @stripe))
    assert_equal 999 + 999, monthly(sub), "Companions $9.99 + a further Small $9.99"

    reconcile.propose_end(agent("Aria")).then { |change| reconcile.confirm(change, digest: change.digest) }
    assert_equal 999, monthly(sub), "the plan again includes the one left: $9.99 in all"
    assert_equal "included", ResidentSubscription.live.find_by!(agent: second).rate

    change = reconcile.propose_end(second)
    assert_equal [ { "op" => "end_bill", "agent_id" => second.id } ], change.ops
    reconcile.confirm(change, digest: change.digest)
    assert @stripe.subscriptions.retrieve(sub).cancel_at_period_end, "the bill, plan and all, ends at the period's end"
  end

  test "a Medium promoted to the included one drops from $39.99 to $30" do
    @account.update!(chosen_plan: "partners")
    _, sub = first_bill!("conversation", name: "Aria")
    medium = @account.agents.where.not(id: agent("Aria").id).first
    go!(Billing::Reconcile.add_ops(@account, medium, Billing::Tier.find!("life").offer, client: @stripe))
    assert_equal 2999 + 0 + 3999, monthly(sub)
    reconcile.propose_end(agent("Aria")).then { |change| reconcile.confirm(change, digest: change.digest) }
    assert_equal 2999 + 3000, monthly(sub)
  end

  test "a granted plan is a free account: its Small costs nothing" do
    @account.update!(granted_plan: "partners")
    _, sub = first_bill!("conversation")
    assert_equal 0, monthly(sub)
    assert_equal "partners", @account.reload.plan.id
  end

  test "a plan code is a free account at every size, Companions included" do
    BillingCode.create!(code: "FREE-COMPANIONS", effect: "plan:companions", created_by: users(:site_admin_user))
    BillingCode.redeem!(code: "FREE-COMPANIONS", account: @account, by: @owner)
    _, sub = first_bill!("life")
    assert_equal 3000, monthly(sub), "only the difference for the bigger resident"
  end

  test "the free days are Companions and its Small: $9.99 once they end" do
    order, url = paid_birth.start_trial!(account: @account, creator: @owner, open_beginning: true,
      attributes: { name: "Aria", system_prompt: "", model_id: "openrouter/auto" },
      success_url: "https://house.test/ok", cancel_url: "https://house.test/no")
    assert url
    params, = @stripe.checkout_sessions.sole
    assert_equal 999, params[:line_items].sum { |item| ADVERTISED.fetch(item[:price]) * item[:quantity] }
    assert_equal 14, params.dig(:subscription_data, :trial_period_days)
    assert order.trial?
  end

  test "a bill from before plans included a resident stays per resident: a Small added is $9.99, with no plan" do
    rows = { agents(:research_assistant) => CONVERSATION_PRICE }
    @stripe.put_shared_subscription(id: "sub_old", account: @account, customer: "cus_1", status: "active",
      items: rows.map { |agent, price| { agent:, price: } })
    seed_bill!("sub_old")
    go!(Billing::Reconcile.add_ops(@account, agents(:code_reviewer), Billing::Tier.find!("conversation").offer, client: @stripe))
    assert_equal 999 + 999, monthly("sub_old")
    assert_empty AccountSubscription.where(account: @account)
  end

  test "the account paying at cost stays $31" do
    BillingCode.create!(code: "AT-COST", effect: "at_cost", created_by: users(:site_admin_user))
    BillingCode.redeem!(code: "AT-COST", account: @account, by: @owner)
    @account.update!(granted_plan: "colleagues")
    @stripe.put_shared_subscription(id: "sub_pepe", account: @account, customer: "cus_1", status: "active",
      items: [ { agent: agents(:research_assistant), price: LIFE_AT_COST_HETZNER_PRICE },
               { agent: agents(:code_reviewer), price: WORK_AT_COST_HETZNER_PRICE } ])
    seed_bill!("sub_pepe")
    assert_equal 3100, monthly("sub_pepe")
    assert_nil @account.reload.plan_to_pay_for
    assert_not Billing::Included.available?(@account)
  end

end
