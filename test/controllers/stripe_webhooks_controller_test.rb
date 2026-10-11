require "test_helper"
require "support/fake_stripe"

class StripeWebhooksControllerTest < ActionDispatch::IntegrationTest

  include FakeStripe::Helpers
  include ActiveJob::TestHelper

  def payload(id = "evt_1")
    { id: id, object: "event", type: "customer.subscription.updated",
      data: { object: { object: "subscription", id: "sub_1" } } }.to_json
  end

  def signed_post(body)
    timestamp = Time.now.to_i
    signature = Stripe::Webhook::Signature.compute_signature(Time.at(timestamp), body, "whsec_test_fake")
    post stripe_webhook_path, params: body,
      headers: { "Content-Type" => "application/json", "Stripe-Signature" => "t=#{timestamp},v1=#{signature}" }
  end

  test "records a signed event and enqueues it" do
    assert_enqueued_with(job: Billing::ProcessStripeEventJob) { signed_post(payload) }

    assert_response :ok
    event = StripeEvent.find_by!(stripe_event_id: "evt_1")
    assert_equal "received", event.status
    assert_equal "sub_1", event.subscription_id
  end

  test "refuses an unsigned or wrongly signed event" do
    post stripe_webhook_path, params: payload, headers: { "Content-Type" => "application/json", "Stripe-Signature" => "t=1,v1=bad" }

    assert_response :bad_request
    assert_not StripeEvent.exists?(stripe_event_id: "evt_1")
  end

  test "a retry of an unfinished event re-enqueues it; a processed one is a no-op" do
    signed_post(payload)
    event = StripeEvent.find_by!(stripe_event_id: "evt_1")
    event.update!(status: "failed")
    assert_enqueued_with(job: Billing::ProcessStripeEventJob) { signed_post(payload) }
    assert_response :ok, response.body

    event.update!(status: "processed")
    assert_no_enqueued_jobs(only: Billing::ProcessStripeEventJob) { signed_post(payload) }
    assert_response :ok
    assert_equal 1, StripeEvent.where(stripe_event_id: "evt_1").count
  end


  test "a signed retry recovers an event whose worker died mid-attempt, but not one still being worked" do
    signed_post(payload)
    event = StripeEvent.find_by!(stripe_event_id: "evt_1")
    event.update_columns(status: "processing", attempts: StripeEvent::MAX_ATTEMPTS, updated_at: 1.minute.ago)
    assert_no_enqueued_jobs(only: Billing::ProcessStripeEventJob) { signed_post(payload) }

    event.update_columns(updated_at: 11.minutes.ago)
    assert_enqueued_with(job: Billing::ProcessStripeEventJob, args: [ event.id ]) { signed_post(payload) }
    assert_response :ok
  end

end
