require "test_helper"

class Billing::AccountPlanTest < ActiveSupport::TestCase

  test "three plans in order, each priced with its Small resident included" do
    plans = Billing::AccountPlan.all
    assert_equal %w[companions partners colleagues], plans.map(&:id)
    assert_equal %w[Companions Partners Colleagues], plans.map(&:name)
    # Daniel, ePoEyY JygPKB 2026-11-14: "$9.99 / $29.99 / $59.99".
    assert_equal %w[9.99 29.99 59.99].map { |usd| BigDecimal(usd) }, plans.map(&:monthly_usd)
    assert_equal plans.map(&:monthly_usd), plans.map(&:from_usd), "the least an account on the plan pays is the plan"
    assert_equal plans, plans.reverse.sort
    assert Billing::AccountPlan.find!("companions") < Billing::AccountPlan.find!("partners")
    assert Billing::AccountPlan.find!("partners") < Billing::AccountPlan.find!("colleagues")
    assert_equal "companions", Billing::AccountPlan.default.id
  end

  test "features: one person and nothing more; several people and searches; sub-agents on Colleagues" do
    companions, partners, colleagues = Billing::AccountPlan.all
    assert_equal({ members: "one", swarm_searches: 0, subagents: false, transcription_hours: 5 }, companions.features)
    assert_equal({ members: "several", swarm_searches: 20, subagents: false, transcription_hours: 20 }, partners.features)
    assert_equal({ members: "several", swarm_searches: 100, subagents: true, transcription_hours: 40 }, colleagues.features)
  end

  test "highest picks the higher plan, ignoring blanks and unknowns, Companions by default" do
    assert_equal "companions", Billing::AccountPlan.highest(nil, nil).id
    assert_equal "partners", Billing::AccountPlan.highest("partners", nil).id
    assert_equal "colleagues", Billing::AccountPlan.highest("partners", "colleagues").id
    assert_equal "colleagues", Billing::AccountPlan.highest("colleagues", "partners").id
    assert_equal "partners", Billing::AccountPlan.highest("bogus", "partners").id
  end

  test "JSON prices as decimal strings; Companions is sold like the others" do
    saved = ENV["STRIPE_PRICE_ACCOUNT_COMPANIONS"]
    ENV["STRIPE_PRICE_ACCOUNT_COMPANIONS"] = "price_env_companions"
    json = Billing::AccountPlan.find!("companions").as_json
    assert_equal({ id: "companions", name: "Companions", monthly_usd: "9.99", from_usd: "9.99", purchasable: true,
      features: { members: "one", swarm_searches: 0, subagents: false, transcription_hours: 5 } }, json)
    assert_equal "29.99", Billing::AccountPlan.find!("partners").as_json[:from_usd]
    assert_equal "59.99", Billing::AccountPlan.find!("colleagues").as_json[:from_usd]
  ensure
    ENV["STRIPE_PRICE_ACCOUNT_COMPANIONS"] = saved
  end

  test "Stripe prices: credentials first, then ENV, a list whose first is sold; Companions too" do
    saved = ENV.slice("STRIPE_PRICE_ACCOUNT_PARTNERS", "STRIPE_PRICE_ACCOUNT_COLLEAGUES", "STRIPE_PRICE_ACCOUNT_COMPANIONS")
    ENV["STRIPE_PRICE_ACCOUNT_PARTNERS"] = "price_partners_new, price_partners_old"
    ENV["STRIPE_PRICE_ACCOUNT_COMPANIONS"] = "price_env_companions"
    ENV["STRIPE_PRICE_ACCOUNT_COLLEAGUES"] = "price_env_colleagues"
    partners = Billing::AccountPlan.find!("partners")
    assert_equal %w[price_partners_new price_partners_old], partners.price_ids
    assert_equal "price_partners_new", partners.price_id
    assert partners.purchasable?
    assert_equal partners, Billing::AccountPlan.for_price("price_partners_old")
    assert_equal %w[price_env_companions], Billing::AccountPlan.find!("companions").price_ids
    assert_equal "companions", Billing::AccountPlan.for_price("price_env_companions").id
    assert_nil Billing::AccountPlan.for_price("price_nowhere")
    assert_nil Billing::AccountPlan.for_price(nil)

    prices = { account_colleagues: [ "price_cred_colleagues" ] }
    Rails.application.credentials.stub(:dig, ->(*keys) { keys[0..1] == %i[stripe prices] ? prices[keys[2]] : nil }) do
      assert_equal %w[price_cred_colleagues], Billing::AccountPlan.find!("colleagues").price_ids
    end
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  test "transcription is the account's and shown; backup space is each resident's and not a plan's" do
    assert_equal [ 5, 20, 40 ], Billing::AccountPlan.all.map(&:transcription_hours)
    Billing::AccountPlan.all.each do |plan|
      assert_equal plan.transcription_hours, plan.features[:transcription_hours]
      assert_not_respond_to plan, :backup_gb
      assert_not plan.features.key?(:backup_gb)
    end
  end


end
