# Saving the card an account pays with, from inside the creation wizard.
# Stripe's own embedded form takes the card and billing address; the house
# only learns brand, last four and expiry. Only the account's owner pays.
class Accounts::BillingCardsController < ApplicationController

  require_feature_enabled :agents
  before_action :require_account_owner!

  rescue_from Billing::NotConfigured, Billing::NotReady, Billing::InvalidSubscription do |error|
    render json: { error: error.message }, status: :unprocessable_entity
  end
  rescue_from Stripe::StripeError do
    render json: { error: "Stripe couldn't complete that just now. Please try again." }, status: :bad_gateway
  end

  def create
    render json: Billing::PaymentMethod.new(account: current_account).start_setup!
  end

  def complete
    method = Billing::PaymentMethod.new(account: current_account).finish_setup!(params.require(:session_id))
    audit("billing_card_saved", current_account, brand: method&.brand, last4: method&.last4)
    render json: { payment_method: method&.as_json }
  end

end
