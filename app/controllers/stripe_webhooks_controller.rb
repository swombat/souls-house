# Stripe posts billing events here. Unauthenticated except for the signature.
# Each event is recorded before anything acts on it, then applied by a job
# that re-fetches the subscription from Stripe rather than trusting this copy.
class StripeWebhooksController < ApplicationController

  skip_before_action :verify_authenticity_token
  skip_before_action :require_authentication

  def create
    secret = Billing.webhook_secret
    return head(:service_unavailable) if secret.blank?

    payload = request.raw_post
    event = Stripe::Webhook.construct_event(payload, request.headers["Stripe-Signature"].to_s, secret)
    record = StripeEvent.record!(stripe_event_id: event.id, event_type: event.type, payload: JSON.parse(payload))
    Billing::ProcessStripeEventJob.perform_later(record.id) unless record.processed? || record.status == "processing"

    head :ok
  rescue Stripe::SignatureVerificationError
    head :bad_request
  rescue JSON::ParserError
    head :bad_request
  end

end
