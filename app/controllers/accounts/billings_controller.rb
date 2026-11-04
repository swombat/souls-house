# The account's Billing tab: each hosted resident's plan, a Stripe Checkout
# button per plan, and Stripe's Customer Portal for everything after that.
# Members can see it; only the account owner can pay or change billing.
class Accounts::BillingsController < ApplicationController

  require_feature_enabled :agents
  before_action :require_account_manager!
  before_action :require_account_owner!, only: [ :checkout, :plan_change, :portal ]

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
        can_pay: current_account.owned_by?(Current.user),
        contact_email: Billing.contact_email
      },
      tiers: Billing::Tier.all.as_json,
      offers: current_account.purchasable_offers.as_json,
      codes: {
        eligible_rates: current_account.eligible_rates,
        redemptions: current_account.billing_code_redemptions.live.includes(:billing_code, :redeemed_by).map(&:as_json),
        redeem_url: account_billing_codes_path(current_account)
      },
      # Where a paid resident can move: every purchasable offer; the tab
      # keeps the resident's own rate.
      change_offers: Billing::Tier.all.flat_map(&:offers).select(&:purchasable?).as_json,
      residents: residents_json
    }
  end

  def checkout
    agent = billable_agents.find(params[:agent_id])
    tier = Billing::Tier.find(params[:tier]) || raise(ActionController::BadRequest, "Unknown plan")
    rate = params[:rate].presence || "standard"
    raise ActionController::BadRequest, "Unknown rate" unless Billing::Tier::RATES.include?(rate)
    url = Billing::Checkout.new(
      agent: agent,
      tier: tier,
      rate: rate,
      success_url: account_billing_url(current_account, checkout: "success"),
      cancel_url: account_billing_url(current_account)
    ).url
    inertia_location url
  rescue Billing::AlreadySubscribed, Billing::NotConfigured, Billing::NotEligible, Billing::NotReady, Stripe::StripeError => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  def portal
    inertia_location Billing::Portal.new(account: current_account, return_url: account_billing_url(current_account)).url
  rescue Billing::NotConfigured, Stripe::StripeError => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  # Another plan at the same rate, now, prorated by Stripe.
  def plan_change
    agent = billable_agents.find(params[:agent_id])
    tier = Billing::Tier.find(params[:tier]) || raise(ActionController::BadRequest, "Unknown plan")
    subscription = Billing::PlanChange.new(agent: agent, tier: tier).call
    audit("change_plan", agent, tier: tier.id, now: subscription.tier, rate: subscription.rate,
      stripe_subscription_id: subscription.stripe_subscription_id)
    # What Stripe has after the change, not what was asked: the two differ
    # only if another change raced this one.
    now_on = subscription.tier_record&.name || subscription.tier
    redirect_to account_billing_path(current_account),
      notice: "#{agent.name} is now on #{now_on}. Stripe puts the difference for the rest of this period on the next invoice."
  rescue Billing::PlanChange::Refused, Billing::NotConfigured, Billing::InvalidSubscription, Stripe::StripeError => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  private

  # Disabled residents don't appear and can't be paid for: re-enable one first.
  def billable_agents
    current_account.agents.hosted.active
  end

  def residents_json
    entitlements = ResidentEntitlement.includes(:current_subscription)
      .where(agent_id: billable_agents.select(:id)).index_by(&:agent_id)

    billable_agents.by_name.map do |agent|
      { id: agent.to_param, name: agent.name, colour: agent.colour, entitlement: entitlements[agent.id]&.as_json }
    end
  end

  def billing_error_message(error)
    return "Stripe couldn't complete that just now. Please try again." if error.is_a?(Stripe::StripeError)

    error.message
  end

end
