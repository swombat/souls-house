require "test_helper"
require "support/fake_stripe"

class BillingCodeTest < ActiveSupport::TestCase

  # The Stripe price ENV: offers are purchasable only with a price configured.
  include FakeStripe::Helpers

  setup do
    @admin = users(:site_admin_user)
    @account = accounts(:personal_account)
    @owner = users(:user_1)
    @now = Time.zone.parse("2026-10-28 16:00")
  end

  def code(**attributes)
    BillingCode.create!({ code: "PEPE-AT-COST", effect: "at_cost", created_by: @admin }.merge(attributes))
  end

  test "a redeemed code is the account's grant: the effect is copied, the count kept, the rate held" do
    code
    assert_equal %w[standard], @account.eligible_rates
    assert_empty @account.purchasable_offers.select(&:at_cost?)

    redemption = BillingCode.redeem!(code: " pepe-at-cost ", account: @account, by: @owner, now: @now)

    assert_equal "at_cost", redemption.effect
    assert_equal @now, redemption.redeemed_at
    assert_equal 1, BillingCode.sole.redemptions_count
    assert_equal %w[standard at_cost], @account.reload.eligible_rates
    at_cost = Billing::Tier.find!("life").offer("at_cost")
    assert @account.eligible_for?(at_cost)
    assert_equal redemption, @account.grant_for(at_cost)
    assert_nil @account.grant_for(Billing::Tier.find!("life").offer("standard"))
    assert_equal %w[conversation conversation_at_cost life life_at_cost work work_at_cost],
      @account.purchasable_offers.map(&:id)
  end

  test "unknown, used, withdrawn, expired and exhausted codes are refused, each with its reason" do
    error = assert_raises(BillingCode::Refused) { BillingCode.redeem!(code: "NOPE", account: @account, by: @owner) }
    assert_match(/isn't one this house knows/, error.message)

    record = code(max_redemptions: 1)
    BillingCode.redeem!(code: record.code, account: @account, by: @owner, now: @now)
    error = assert_raises(BillingCode::Refused) { BillingCode.redeem!(code: record.code, account: @account, by: @owner) }
    assert_match(/already used/, error.message)
    other = accounts(:team_account)
    error = assert_raises(BillingCode::Refused) { BillingCode.redeem!(code: record.code, account: other, by: @owner) }
    assert_match(/as many times as it can be/, error.message)

    expired = code(code: "OLD", expires_at: @now - 1.minute)
    error = assert_raises(BillingCode::Refused) { BillingCode.redeem!(code: "OLD", account: other, by: @owner, now: @now) }
    assert_match(/expired/, error.message)
    assert_not expired.redeemable?(@now)

    revoked = code(code: "GONE")
    revoked.revoke!(now: @now)
    error = assert_raises(BillingCode::Refused) { BillingCode.redeem!(code: "GONE", account: other, by: @owner) }
    assert_match(/withdrawn/, error.message)
  end

  test "withdrawing a code stops new redemptions only; withdrawing a redemption ends that account's grant" do
    record = code
    redemption = BillingCode.redeem!(code: record.code, account: @account, by: @owner, now: @now)
    record.revoke!(now: @now)
    assert @account.reload.eligible_for?(Billing::Tier.find!("life").offer("at_cost")), "the grant already made stays"

    redemption.withdraw!(by: @admin, now: @now + 1.hour)
    assert_not @account.reload.eligible_for?(Billing::Tier.find!("life").offer("at_cost"))
    assert_nil @account.grant_for(Billing::Tier.find!("life").offer("at_cost"))
  end

  test "codes are upper-case letters, digits and dashes, unique regardless of case, and can be made up" do
    code(code: "mixed-Case-1")
    assert_equal "MIXED-CASE-1", BillingCode.sole.code
    assert_raises(ActiveRecord::RecordInvalid) { code(code: "Mixed-case-1") }
    assert_raises(ActiveRecord::RecordInvalid) { code(code: "no spaces") }
    assert_raises(ActiveRecord::RecordInvalid) { code(code: "AB") }
    assert_raises(ActiveRecord::RecordInvalid) { code(code: "ZZZ", effect: "half_price") }
    assert_raises(ActiveRecord::RecordInvalid) { code(code: "ZZZ", max_redemptions: 0) }

    generated = BillingCode.generate
    assert_match BillingCode::FORMAT, generated
    assert_equal 10, generated.length
  end

  test "a code for one size lets the account buy that size at cost and no other" do
    code(effect: "at_cost:life")
    redemption = BillingCode.redeem!(code: "PEPE-AT-COST", account: @account, by: @owner, now: @now)

    assert_equal %w[standard at_cost], @account.eligible_rates
    assert_equal redemption, @account.grant_for(Billing::Tier.find!("life").offer("at_cost"))
    assert_nil @account.grant_for(Billing::Tier.find!("work").offer("at_cost"))
    assert_equal %w[conversation life life_at_cost work], @account.purchasable_offers.map(&:id)

    redemption.withdraw!(by: @admin)
    assert_equal %w[conversation life work], @account.reload.purchasable_offers.map(&:id)
  end

  test "a free-plan code gives the account that plan while the redemption lives, and never lowers a higher grant" do
    code(effect: "plan:partners")
    assert_equal "companions", @account.plan.id

    redemption = BillingCode.redeem!(code: "PEPE-AT-COST", account: @account, by: @owner, now: @now)
    assert_equal "partners", @account.reload.plan.id
    assert_equal "grant", @account.plan_source
    assert_equal %w[standard], @account.eligible_rates, "a plan code grants no rate"

    @account.update!(granted_plan: "colleagues")
    assert_equal "colleagues", @account.plan.id
    @account.update!(granted_plan: nil)

    redemption.withdraw!(by: @admin)
    assert_equal "companions", @account.reload.plan.id
    assert_equal "default", @account.plan_source
  end

  test "a free-plan code is refused while the account pays for that plan or a lower one, so nothing is charged twice" do
    code(effect: "plan:partners")
    paid = AccountSubscription.create!(account: @account, stripe_subscription_id: "sub_plan", stripe_status: "active",
      plan: "partners", stripe_price_id: Billing::AccountPlan.find!("partners").price_id)

    error = assert_raises(BillingCode::Refused) { BillingCode.redeem!(code: "PEPE-AT-COST", account: @account, by: @owner) }
    assert_match(/paying for Partners/, error.message)
    assert_equal 0, BillingCode.sole.redemptions_count

    paid.update!(stripe_status: "canceled")
    assert BillingCode.redeem!(code: "PEPE-AT-COST", account: @account, by: @owner)
  end

  test "only known effects make a code" do
    assert_includes BillingCode::EFFECTS, "at_cost:conversation"
    assert_includes BillingCode::EFFECTS, "plan:colleagues"
    assert_not_includes BillingCode::EFFECTS, "plan:companions"
    assert_not BillingCode.new(code: "X-Y-Z", effect: "plan:everything", created_by: @admin).valid?
    assert_equal "The Partners plan, free", BillingCode.label("plan:partners")
    assert_equal "At cost, every size", BillingCode.label("at_cost")
  end

  test "a free-plan code waits for anything the account could still pay for that plan: an unpaid plan, an open Checkout, a sent change" do
    code(effect: "plan:partners")
    redeem = -> { BillingCode.redeem!(code: "PEPE-AT-COST", account: @account, by: @owner) }
    paid = AccountSubscription.create!(account: @account, stripe_subscription_id: "sub_plan", stripe_status: "unpaid",
      plan: "partners", stripe_price_id: Billing::AccountPlan.find!("partners").price_id)
    assert_match(/paying for Partners/, assert_raises(BillingCode::Refused, &redeem).message)
    paid.update!(stripe_status: "canceled")

    attempt = AccountPlanCheckoutAttempt.create!(account: @account, plan: "partners", stripe_price_id: "price_x",
      idempotency_key: "key-1", create_params: { "mode" => "subscription" })
    assert_match(/still being confirmed/, assert_raises(BillingCode::Refused, &redeem).message)
    attempt.update!(resolved_at: @now)

    change = BillChange.create!(account: @account, stripe_subscription_id: "sub_acct", idempotency_key: "key-2",
      ops: [ { "op" => "plan", "price" => "price_x" } ], base: {}, lines: { "price_x" => 1 }, params: {}, quote: {},
      state: "submitted", submitted_at: @now)
    assert_match(/still being confirmed/, assert_raises(BillingCode::Refused, &redeem).message)
    change.abandon!("test")

    assert redeem.call
    assert_equal "partners", @account.reload.plan.id
  end

end
