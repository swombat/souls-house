# The account's Billing tab: each hosted resident's plan, a Stripe Checkout
# button per plan, and Stripe's Customer Portal for everything after that.
# Members can see it; only the account owner can pay or change billing.
class Accounts::BillingsController < ApplicationController

  require_feature_enabled :agents
  before_action :require_account_manager!
  before_action :require_account_owner!, only: [ :checkout, :add_resident, :plan_change, :portal, :account_plan_checkout,
    :account_plan_change ]

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
      account_plans: Billing::AccountPlan.all.as_json,
      account_plan: current_account.account_plan_json,
      trial: Billing::Trial.as_json_for(current_account),
      offers: current_account.purchasable_offers.as_json,
      codes: {
        eligible_rates: current_account.eligible_rates,
        redemptions: current_account.billing_code_redemptions.live.includes(:billing_code, :redeemed_by).map(&:as_json),
        redeem_url: account_billing_codes_path(current_account)
      },
      # Where a paid resident can move: every purchasable offer; the tab
      # keeps the resident's own rate.
      change_offers: Billing::Tier.all.flat_map(&:offers).select(&:purchasable?).as_json,
      residents: residents_json,
      pending_add: pending_add_json
    }
  end

  # With a live subscription, a resident joins it (Billing::AddItem): the
  # owner is shown the quote, and confirms it with add_resident.
  def checkout
    agent = billable_agents.find(params[:agent_id])
    tier = Billing::Tier.find(params[:tier]) || raise(ActionController::BadRequest, "Unknown plan")
    rate = params[:rate].presence || "standard"
    raise ActionController::BadRequest, "Unknown rate" unless Billing::Tier::RATES.include?(rate)
    if Billing::AddItem.applies?(current_account)
      attempt = Billing::AddItem.new(agent: agent, tier: tier, rate: rate).quote
      return redirect_to account_billing_path(current_account, add: attempt.id)
    end

    url = Billing::Checkout.new(
      agent: agent,
      tier: tier,
      rate: rate,
      success_url: account_billing_url(current_account, checkout: "success"),
      cancel_url: account_billing_url(current_account)
    ).url
    inertia_location url
  rescue Billing::AlreadySubscribed, Billing::NotConfigured, Billing::NotEligible, Billing::NotReady,
    Billing::AddItem::Refused, Billing::InvalidSubscription, Stripe::StripeError => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  # The owner confirmed the quote they were shown. A quote that no longer
  # holds is made again and shown, with nothing charged.
  def add_resident
    attempt = BillingCheckoutAttempt.where(account: current_account, kind: Billing::AddItem::KIND).find(params[:attempt_id])
    agent = billable_agents.find(attempt.agent_id)
    row = Billing::AddItem.new(agent: agent).confirm!(attempt, digest: params[:digest].to_s)
    audit("add_resident_to_subscription", agent, tier: row.tier, rate: row.rate,
      stripe_subscription_id: row.stripe_subscription_id, stripe_subscription_item_id: row.stripe_subscription_item_id)
    redirect_to account_billing_path(current_account),
      notice: "#{agent.name} is on #{row.tier_record&.name || row.tier} now. The part of this period goes on the next bill."
  rescue Billing::AddItem::QuoteChanged => error
    begin
      fresh = Billing::AddItem.new(agent: agent, tier: Billing::Tier.find!(attempt.tier), rate: attempt.rate).quote
      redirect_to account_billing_path(current_account, add: fresh.id), alert: error.message
    rescue Billing::AlreadySubscribed, Billing::NotConfigured, Billing::NotEligible, Billing::NotReady,
      Billing::AddItem::Refused, Billing::InvalidSubscription, Stripe::StripeError => again
      redirect_to account_billing_path(current_account), alert: billing_error_message(again)
    end
  rescue Billing::AlreadySubscribed, Billing::NotConfigured, Billing::NotEligible, Billing::NotReady,
    Billing::AddItem::Refused, Billing::InvalidSubscription, Stripe::StripeError => error
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

  # The account's plan, bought through Stripe Checkout. Moving between paid
  # plans is account_plan_change; cancelling is in Stripe's portal.
  def account_plan_checkout
    plan = Billing::AccountPlan.find(params[:plan]) || raise(ActionController::BadRequest, "Unknown plan")
    url = Billing::AccountPlanCheckout.new(
      account: current_account,
      plan: plan,
      success_url: account_billing_url(current_account, checkout: "success"),
      cancel_url: account_billing_url(current_account)
    ).url
    audit("start_account_plan_checkout", current_account, plan: plan.id)
    inertia_location url
  rescue Billing::AccountPlanCheckout::Refused, Billing::AlreadySubscribed, Billing::NotConfigured, Billing::NotReady,
    Stripe::StripeError => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  # Partners and Colleagues, either way, now, prorated by Stripe.
  def account_plan_change
    plan = Billing::AccountPlan.find(params[:plan]) || raise(ActionController::BadRequest, "Unknown plan")
    subscription = Billing::AccountPlanChange.new(account: current_account, plan: plan).call
    audit("change_account_plan", current_account, plan: plan.id, now: subscription.plan,
      stripe_subscription_id: subscription.stripe_subscription_id)
    now_on = subscription.plan_record&.name || subscription.plan
    redirect_to account_billing_path(current_account),
      notice: "The account is now on #{now_on}. Stripe puts the difference for the rest of this period on the next invoice."
  rescue Billing::AccountPlanChange::Refused, Billing::NotConfigured, Billing::InvalidSubscription, Stripe::StripeError => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  private

  # The quote the owner is being asked to confirm, if one was just made.
  def pending_add_json
    return nil if params[:add].blank?

    attempt = BillingCheckoutAttempt.unresolved.find_by(id: params[:add], account: current_account,
      kind: Billing::AddItem::KIND, submitted_at: nil)
    return nil unless attempt

    quote = attempt.quote
    { attempt_id: attempt.id, digest: Billing::AddItem.digest(quote), resident_name: attempt.agent.name,
      plan: Billing::Tier.find(attempt.tier)&.name || attempt.tier, rate: attempt.rate, currency: quote["currency"],
      added_cents: quote["added_next"], next_total_cents: quote["next_total"], recurring_cents: quote["recurring_total"],
      next_at: quote["next_at"] && Time.zone.at(quote["next_at"]).to_date.iso8601 }
  end

  # Disabled residents don't appear and can't be paid for: re-enable one first.
  def billable_agents
    current_account.agents.hosted.active
  end

  def residents_json
    entitlements = ResidentEntitlement.includes(:current_subscription)
      .where(agent_id: billable_agents.select(:id)).index_by(&:agent_id)

    billable_agents.by_name.map do |agent|
      entitlement = entitlements[agent.id]
      # has_payment_method isn't sent: whether Stripe will charge at the
      # trial's end depends on the customer's default card, which the house
      # doesn't sync; the wizard reads it live (Billing::PaymentMethod).
      { id: agent.to_param, name: agent.name, colour: agent.colour, entitlement: entitlement&.as_json,
        trial_ends_at: entitlement&.current_subscription&.trial_ends_at&.iso8601 }
    end
  end

  def billing_error_message(error)
    return "Stripe couldn't complete that just now. Please try again." if error.is_a?(Stripe::StripeError)

    error.message
  end

end
