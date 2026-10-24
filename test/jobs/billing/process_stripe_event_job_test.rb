require "test_helper"
require "support/fake_stripe"

class Billing::ProcessStripeEventJobTest < ActiveJob::TestCase

  include FakeStripe::Helpers

  setup do
    @agent = agents(:research_assistant)
    @stripe = FakeStripe.new
    BillingCustomer.create!(account: @agent.account, stripe_customer_id: "cus_1")
    @event = StripeEvent.record!(stripe_event_id: "evt_1", event_type: "customer.subscription.updated",
      payload: { "data" => { "object" => { "object" => "subscription", "id" => "sub_1" } } })
  end

  test "a crashed or failed event is reprocessed on retry and then applied once" do
    Billing.stub(:client, @stripe) do
      Billing::ProcessStripeEventJob.perform_now(@event.id)
      @event.reload
      assert_equal "failed", @event.status
      assert_equal 1, @event.attempts

      @stripe.put_subscription(id: "sub_1", agent: @agent, customer: "cus_1",
        price: FakeStripe::Helpers::CONVERSATION_PRICE, status: "active")
      Billing::ProcessStripeEventJob.perform_now(@event.id)
      assert_equal "processed", @event.reload.status
      assert ResidentEntitlement.find_by!(agent: @agent).active?

      Billing::ProcessStripeEventJob.perform_now(@event.id)
      assert_equal 2, @event.reload.attempts, "a processed event is not claimed again"
    end
  end

  test "a worker killed mid-attempt is recovered once it goes stale, not before" do
    attempt = StripeEvent.claim(@event.id)
    assert_equal 1, attempt
    # The worker dies here: the event is left in processing.
    assert_nil StripeEvent.claim(@event.id), "a live worker's claim is respected"

    travel 11.minutes do
      assert_equal 2, StripeEvent.claim(@event.id)
    end
  end

  test "two workers can't both run an attempt, and a late one can't overwrite a newer result" do
    first = StripeEvent.claim(@event.id)
    assert_nil StripeEvent.claim(@event.id)

    travel 11.minutes do
      second = StripeEvent.claim(@event.id)
      assert @event.finish!(attempt: second, status: "processed")
      assert_not @event.finish!(attempt: first, status: "failed", error: "late")
    end
    assert_equal "processed", @event.reload.status
    assert_nil @event.last_error
  end

  test "a worker killed on the final attempt is escalated by the sweeper" do
    @event.update_columns(status: "processing", attempts: StripeEvent::MAX_ATTEMPTS, updated_at: 11.minutes.ago)
    reports = []
    subscriber = Object.new
    subscriber.define_singleton_method(:report) { |error, **| reports << error }
    Rails.error.subscribe(subscriber)

    assert_no_enqueued_jobs(only: Billing::ProcessStripeEventJob) { Billing::SweepJob.perform_now }

    @event.reload
    assert_equal "failed", @event.status
    assert_match(/final attempt/, @event.last_error)
    assert(reports.any? { |error| error.is_a?(Billing::SweepJob::AbandonedEvent) })
  ensure
    Rails.error.unsubscribe(subscriber) if subscriber
  end

  test "a Stripe retry recovers a stale processing event through the webhook path" do
    @event.update_columns(status: "processing", attempts: StripeEvent::MAX_ATTEMPTS, updated_at: 11.minutes.ago)
    assert @event.reload.recoverable?
    @event.update_columns(updated_at: 1.minute.ago)
    assert_not @event.reload.recoverable?
  end

  test "the sweeper retries events left unfinished" do
    @event.update_columns(status: "processing", updated_at: 11.minutes.ago)

    assert_enqueued_with(job: Billing::ProcessStripeEventJob, args: [ @event.id ]) do
      Billing::SweepJob.perform_now
    end
  end

  test "the sweeper gives up after five attempts" do
    @event.update_columns(status: "failed", attempts: 5, updated_at: 1.hour.ago)

    assert_no_enqueued_jobs(only: Billing::ProcessStripeEventJob) { Billing::SweepJob.perform_now }
  end

  test "finds the subscription on checkout sessions and invoices" do
    session = StripeEvent.new(payload: { "data" => { "object" => { "object" => "checkout.session", "subscription" => "sub_a" } } })
    invoice = StripeEvent.new(payload: { "data" => { "object" => { "object" => "invoice",
      "parent" => { "subscription_details" => { "subscription" => "sub_b" } } } } })
    other = StripeEvent.new(payload: { "data" => { "object" => { "object" => "customer", "id" => "cus_1" } } })

    assert_equal "sub_a", session.subscription_id
    assert_equal "sub_b", invoice.subscription_id
    assert_nil other.subscription_id
  end

end
