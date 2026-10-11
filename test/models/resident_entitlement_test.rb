require "test_helper"
require "support/fake_stripe"

class ResidentEntitlementTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
    @now = Time.zone.parse("2026-10-11 12:00")
  end

  def subscription(id, status, tier: "starter")
    ResidentSubscription.create!(agent: @agent, account: @account, stripe_subscription_id: id,
      tier: tier, stripe_status: status)
  end

  def entitlement
    @entitlement ||= ResidentEntitlement.for_agent!(@agent)
  end

  test "a failed or abandoned first checkout grants nothing" do
    sub = subscription("sub_1", "incomplete")
    assert_not entitlement.apply_subscription!(sub, now: @now)
    sub.update!(stripe_status: "incomplete_expired")
    assert_not entitlement.apply_subscription!(sub, now: @now)

    entitlement.reload
    assert entitlement.pending?
    assert_nil entitlement.current_subscription
    assert_nil entitlement.tier
  end

  test "a paid subscription becomes current and activates the plan" do
    sub = subscription("sub_1", "active", tier: "studio")
    assert entitlement.apply_subscription!(sub, now: @now)

    entitlement.reload
    assert entitlement.active?
    assert entitlement.paid?
    assert_equal "stripe", entitlement.source
    assert_equal "studio", entitlement.tier
    assert_equal sub, entitlement.current_subscription
  end

  test "past_due starts grace once; replaying it neither restarts grace nor lifts a hold" do
    sub = subscription("sub_1", "active")
    entitlement.apply_subscription!(sub, now: @now)

    sub.update!(stripe_status: "past_due")
    entitlement.apply_subscription!(sub, now: @now)
    assert entitlement.reload.grace?
    assert_equal @now + 14.days, entitlement.grace_deadline

    entitlement.apply_subscription!(sub, now: @now + 3.days)
    assert_equal @now, entitlement.reload.grace_started_at

    assert entitlement.expire_grace!(now: @now + 14.days)
    assert entitlement.reload.held?

    entitlement.apply_subscription!(sub, now: @now + 15.days)
    assert entitlement.reload.held?
  end

  test "grace holds at its deadline while Stripe still says past_due, and not before" do
    sub = subscription("sub_1", "active")
    entitlement.apply_subscription!(sub, now: @now)
    sub.update!(stripe_status: "past_due")
    entitlement.apply_subscription!(sub, now: @now)

    assert_not entitlement.expire_grace!(now: @now + 13.days)
    assert entitlement.reload.grace?

    Billing::SweepJob.perform_now(now: @now + 14.days + 1.minute)
    assert entitlement.reload.held?
  end

  test "paying the outstanding invoice lifts the hold" do
    sub = subscription("sub_1", "active")
    entitlement.apply_subscription!(sub, now: @now)
    sub.update!(stripe_status: "unpaid")
    entitlement.apply_subscription!(sub, now: @now)
    assert entitlement.reload.held?

    sub.update!(stripe_status: "active")
    entitlement.apply_subscription!(sub, now: @now + 1.day)
    entitlement.reload
    assert entitlement.active?
    assert_equal @now + 1.day, entitlement.hold_released_at
  end

  test "a stale subscription's cancellation can't hold a resident whose replacement is paid" do
    old = subscription("sub_old", "active")
    entitlement.apply_subscription!(old, now: @now)
    old.update!(stripe_status: "canceled")
    entitlement.apply_subscription!(old, now: @now)
    assert entitlement.reload.held?

    replacement = subscription("sub_new", "active", tier: "studio")
    entitlement.apply_subscription!(replacement, now: @now + 1.day)
    assert entitlement.reload.active?
    assert_equal replacement, entitlement.current_subscription

    # The old subscription's events arrive late, in any order.
    assert_not entitlement.apply_subscription!(old, now: @now + 2.days)
    old.update!(stripe_status: "unpaid")
    assert_not entitlement.apply_subscription!(old, now: @now + 2.days)
    assert entitlement.reload.active?
    assert_equal "studio", entitlement.tier
  end

  test "a complimentary resident that subscribes and later cancels returns to complimentary" do
    entitlement.update!(state: "complimentary", source: "complimentary", complimentary_granted_at: @now)
    sub = subscription("sub_1", "incomplete")
    assert_not entitlement.apply_subscription!(sub, now: @now)
    assert entitlement.reload.complimentary?

    sub.update!(stripe_status: "active")
    entitlement.apply_subscription!(sub, now: @now)
    assert entitlement.reload.active?

    sub.update!(stripe_status: "canceled")
    entitlement.apply_subscription!(sub, now: @now)
    entitlement.reload
    assert entitlement.complimentary?
    assert_nil entitlement.held_at
  end


  test "free hosting survives a grace deadline as it survives a cancellation" do
    entitlement.update!(state: "complimentary", source: "complimentary", complimentary_granted_at: @now)
    sub = subscription("sub_1", "active")
    entitlement.apply_subscription!(sub, now: @now)
    sub.update!(stripe_status: "past_due")
    entitlement.apply_subscription!(sub, now: @now)
    assert entitlement.reload.grace?

    assert entitlement.expire_grace!(now: @now + 14.days)
    entitlement.reload
    assert entitlement.complimentary?
    assert_equal "complimentary", entitlement.source
    assert_nil entitlement.held_at
    assert_nil entitlement.grace_deadline

    # Stripe later giving up on the invoice changes nothing further.
    sub.update!(stripe_status: "unpaid")
    entitlement.apply_subscription!(sub, now: @now + 20.days)
    assert entitlement.reload.complimentary?
  end

end
