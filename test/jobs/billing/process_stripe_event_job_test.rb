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
        price: FakeStripe::Helpers::STARTER_PRICE, status: "active")
      Billing::ProcessStripeEventJob.perform_now(@event.id)
      assert_equal "processed", @event.reload.status
      assert ResidentEntitlement.find_by!(agent: @agent).active?

      Billing::ProcessStripeEventJob.perform_now(@event.id)
      assert_equal 2, @event.reload.attempts
    end
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
