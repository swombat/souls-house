require "test_helper"
require "support/fake_stripe"

# How a free trial ends, through Stripe's webhook events as Stripe sends them:
# with no card Stripe cancels at day 14 and the resident is put to sleep,
# nothing deleted; with a card added in the portal it becomes active and
# nothing else changes. Every event re-fetches the subscription, so a
# duplicate or an event arriving out of order can't move it backwards.
class Billing::TrialSyncTest < ActiveJob::TestCase

  include FakeStripe::Helpers

  setup do
    travel_to Time.utc(2026, 11, 10, 12)
    Setting.instance.update!(allow_agents: true)
    @account = accounts(:personal_account)
    @account.update!(billing_required: true)
    @stripe = FakeStripe.new
    @trial_end = Time.utc(2026, 11, 24, 12)
    @order, = Billing::PaidBirth.new(client: @stripe).start_trial!(account: @account, creator: users(:user_1),
      open_beginning: false, attributes: { name: "Aria", system_prompt: "Be curious.", model_id: "openrouter/auto" },
      success_url: "https://souls.test/ok", cancel_url: "https://souls.test/no")
    @stripe.complete_checkout_session(@order.stripe_checkout_session_id, subscription_id: "sub_trial", trial_end: @trial_end)
    @events = 0
  end

  # A Stripe event as the webhook records it, for the subscription as Stripe
  # described it when it sent the event (which may be stale by now).
  def event!(type, status:, id: "evt_#{@events += 1}", object: "subscription")
    data = if object == "invoice"
      { "object" => "invoice", "id" => "in_#{id}", "status" => "paid", "amount_paid" => 999,
        "parent" => { "subscription_details" => { "subscription" => "sub_trial" } } }
    else
      { "object" => "subscription", "id" => "sub_trial", "status" => status, "trial_end" => @trial_end.to_i,
        "metadata" => { "birth_order" => @order.reference, "trial" => "1" } }
    end
    payload = { "id" => id, "object" => "event", "type" => type, "data" => { "object" => data } }
    StripeEvent.record!(stripe_event_id: id, event_type: type, payload: payload)
  end

  def process!(event) = Billing.stub(:client, @stripe) { Billing::ProcessStripeEventJob.perform_now(event.id) }

  def agent = @order.reload.agent
  def entitlement = ResidentEntitlement.find_by!(agent: agent)
  def subscription = ResidentSubscription.find_by!(stripe_subscription_id: "sub_trial")

  test "the checkout's events bear the resident once, trialing, however often they arrive" do
    created = event!("customer.subscription.created", status: "trialing")
    completed = event!("checkout.session.completed", status: nil)
    completed.update!(payload: { "id" => completed.stripe_event_id, "type" => "checkout.session.completed",
      "data" => { "object" => { "object" => "checkout.session", "id" => @order.stripe_checkout_session_id,
                                "subscription" => "sub_trial", "mode" => "subscription" } } })

    assert_difference "Agent.count", 1 do
      process!(created)
      process!(completed)
      process!(event!("customer.subscription.created", status: "trialing")) # Stripe's retry under a new id
      process!(created) # the same event again: already processed
    end
    assert @order.reload.born?
    assert_equal "processed", created.reload.status
    assert_equal "trialing", subscription.stripe_status
    assert_equal @trial_end, subscription.trial_end
    assert entitlement.active?
  end

  test "no card at day 14: Stripe cancels, the resident sleeps and nothing is deleted; duplicates change nothing" do
    process!(event!("customer.subscription.created", status: "trialing"))
    resident = agent

    travel_to @trial_end + 1.minute do
      @stripe.set_subscription_status("sub_trial", "canceled")
      deleted = event!("customer.subscription.deleted", status: "canceled")
      process!(deleted)

      held = entitlement
      assert held.held?
      assert_equal Time.current, held.held_at
      assert_not held.funds_calls?
      assert Agent.exists?(resident.id), "the resident is kept, asleep"
      assert_equal "canceled", subscription.stripe_status
      assert_nil subscription.trial_ends_at
      assert_equal BigDecimal("0"), held.allowance_limit

      travel 5.minutes
      process!(deleted)
      process!(event!("customer.subscription.deleted", status: "canceled"))
      assert_equal held.held_at, entitlement.held_at, "a duplicate doesn't restart the hold"
      assert entitlement.held?
    end
  end

  test "out of order: a stale trialing event after the cancellation, or before it, leaves the resident asleep" do
    stale = event!("customer.subscription.updated", status: "trialing")
    process!(event!("customer.subscription.created", status: "trialing"))

    travel_to @trial_end + 1.minute do
      @stripe.set_subscription_status("sub_trial", "canceled")
      # The cancellation arrives first, then an older trialing event.
      process!(event!("customer.subscription.deleted", status: "canceled"))
      process!(stale)
      assert entitlement.held?
      assert_equal "canceled", subscription.stripe_status

      # And a trial_will_end that Stripe sent days ago, retried late.
      process!(event!("customer.subscription.trial_will_end", status: "trialing"))
      assert entitlement.held?
    end
  end

  test "a card added during the trial: active at day 14, nothing else changes; a stale trialing event can't undo it" do
    process!(event!("customer.subscription.created", status: "trialing"))
    resident = agent
    before = entitlement.attributes.slice("tier", "rate", "source")

    travel_to @trial_end + 1.minute do
      # The owner added a card in Stripe's portal; Stripe charged it at the
      # trial's end. The invoice event can arrive before the subscription's.
      @stripe.set_subscription_status("sub_trial", "active")
      process!(event!("invoice.paid", status: nil, object: "invoice"))
      process!(event!("customer.subscription.updated", status: "trialing")) # stale
      process!(event!("customer.subscription.updated", status: "active"))

      assert entitlement.active?
      assert_nil entitlement.held_at
      assert_equal before, entitlement.attributes.slice("tier", "rate", "source")
      assert_equal resident, agent
      assert_equal "active", subscription.stripe_status
      assert_nil subscription.trial_ends_at
      assert_equal @trial_end, subscription.trial_end, "kept for the record"
      assert_equal BigDecimal("10"), entitlement.allowance_limit
      assert_equal 1, ResidentSubscription.where(account: @account).count
    end
  end

end
