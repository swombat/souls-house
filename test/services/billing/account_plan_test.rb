require "test_helper"

class Billing::AccountPlanTest < ActiveSupport::TestCase

  test "three plans in order, with their add-on and from prices" do
    plans = Billing::AccountPlan.all
    assert_equal %w[companions partners colleagues], plans.map(&:id)
    assert_equal %w[Companions Partners Colleagues], plans.map(&:name)
    assert_equal [ 0, 20, 50 ].map { |usd| BigDecimal(usd) }, plans.map(&:monthly_usd)
    assert_equal %w[9.99 29.99 59.99].map { |usd| BigDecimal(usd) }, plans.map(&:from_usd)
    assert_equal plans, plans.reverse.sort
    assert Billing::AccountPlan.find!("companions") < Billing::AccountPlan.find!("partners")
    assert Billing::AccountPlan.find!("partners") < Billing::AccountPlan.find!("colleagues")
    assert_equal "companions", Billing::AccountPlan.default.id
  end

  test "features: one person and nothing more; several people and searches; sub-agents on Colleagues" do
    companions, partners, colleagues = Billing::AccountPlan.all
    assert_equal({ members: "one", swarm_searches: 0, subagents: false }, companions.features)
    assert_equal({ members: "several", swarm_searches: 20, subagents: false }, partners.features)
    assert_equal({ members: "several", swarm_searches: 100, subagents: true }, colleagues.features)
  end

  test "highest picks the higher plan, ignoring blanks and unknowns, Companions by default" do
    assert_equal "companions", Billing::AccountPlan.highest(nil, nil).id
    assert_equal "partners", Billing::AccountPlan.highest("partners", nil).id
    assert_equal "colleagues", Billing::AccountPlan.highest("partners", "colleagues").id
    assert_equal "colleagues", Billing::AccountPlan.highest("colleagues", "partners").id
    assert_equal "partners", Billing::AccountPlan.highest("bogus", "partners").id
  end

  test "JSON leads with from_usd as a decimal string; Companions is never sold" do
    json = Billing::AccountPlan.find!("companions").as_json
    assert_equal({ id: "companions", name: "Companions", monthly_usd: "0.00", from_usd: "9.99", purchasable: false,
      features: { members: "one", swarm_searches: 0, subagents: false } }, json)
    assert_equal "29.99", Billing::AccountPlan.find!("partners").as_json[:from_usd]
    assert_equal "59.99", Billing::AccountPlan.find!("colleagues").as_json[:from_usd]
  end

  test "Stripe prices: credentials first, then ENV, a list whose first is sold; Companions has none" do
    saved = ENV.slice("STRIPE_PRICE_ACCOUNT_PARTNERS", "STRIPE_PRICE_ACCOUNT_COLLEAGUES", "STRIPE_PRICE_ACCOUNT_COMPANIONS")
    ENV["STRIPE_PRICE_ACCOUNT_PARTNERS"] = "price_partners_new, price_partners_old"
    ENV["STRIPE_PRICE_ACCOUNT_COMPANIONS"] = "price_should_be_ignored"
    ENV["STRIPE_PRICE_ACCOUNT_COLLEAGUES"] = "price_env_colleagues"
    partners = Billing::AccountPlan.find!("partners")
    assert_equal %w[price_partners_new price_partners_old], partners.price_ids
    assert_equal "price_partners_new", partners.price_id
    assert partners.purchasable?
    assert_equal partners, Billing::AccountPlan.for_price("price_partners_old")
    assert_empty Billing::AccountPlan.find!("companions").price_ids
    assert_nil Billing::AccountPlan.for_price("price_should_be_ignored")
    assert_nil Billing::AccountPlan.for_price("price_nowhere")
    assert_nil Billing::AccountPlan.for_price(nil)

    prices = { account_colleagues: [ "price_cred_colleagues" ] }
    Rails.application.credentials.stub(:dig, ->(*keys) { keys[0..1] == %i[stripe prices] ? prices[keys[2]] : nil }) do
      assert_equal %w[price_cred_colleagues], Billing::AccountPlan.find!("colleagues").price_ids
    end
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

end
