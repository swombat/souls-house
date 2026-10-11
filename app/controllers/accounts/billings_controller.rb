# The account's Billing tab: each hosted resident's plan, a Stripe Checkout
# button per plan, and Stripe's Customer Portal for everything after that.
# Members can see it; only the account owner can pay or change billing.
class Accounts::BillingsController < ApplicationController

  require_feature_enabled :agents
  before_action :require_account_manager!
  before_action :require_account_owner!, only: [ :checkout, :portal ]

  def show
    if params[:checkout] == "success"
      flash.now[:notice] = "Thanks. The plan will show here as soon as Stripe confirms the payment."
    end

    render inertia: "accounts/billing", props: {
      account: current_account.as_json,
      billing: {
        configured: Billing.configured?,
        test_mode: Billing.test_mode?,
        has_customer: BillingCustomer.exists?(account: current_account),
        can_pay: current_account.owned_by?(Current.user)
      },
      tiers: Billing::Tier.all.as_json,
      residents: residents_json
    }
  end

  def checkout
    agent = current_account.agents.hosted.find(params[:agent_id])
    tier = Billing::Tier.find(params[:tier]) || raise(ActionController::BadRequest, "Unknown plan")
    url = Billing::Checkout.new(
      agent: agent,
      tier: tier,
      success_url: account_billing_url(current_account, checkout: "success"),
      cancel_url: account_billing_url(current_account)
    ).url
    inertia_location url
  rescue Billing::AlreadySubscribed, Billing::NotConfigured, Stripe::StripeError => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  def portal
    inertia_location Billing::Portal.new(account: current_account, return_url: account_billing_url(current_account)).url
  rescue Billing::NotConfigured, Stripe::StripeError => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  private

  def residents_json
    entitlements = ResidentEntitlement.includes(:current_subscription)
      .where(agent_id: current_account.agents.hosted.select(:id)).index_by(&:agent_id)

    current_account.agents.hosted.by_name.map do |agent|
      { id: agent.to_param, name: agent.name, colour: agent.colour, entitlement: entitlements[agent.id]&.as_json }
    end
  end

  def billing_error_message(error)
    return "Stripe couldn't complete that just now. Please try again." if error.is_a?(Stripe::StripeError)

    error.message
  end

end
