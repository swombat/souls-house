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
    assert @account.eligible_for?("at_cost")
    assert_equal redemption, @account.grant_for("at_cost")
    assert_nil @account.grant_for("standard")
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
    assert @account.reload.eligible_for?("at_cost"), "the grant already made stays"

    redemption.withdraw!(by: @admin, now: @now + 1.hour)
    assert_not @account.reload.eligible_for?("at_cost")
    assert_nil @account.grant_for("at_cost")
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

end
