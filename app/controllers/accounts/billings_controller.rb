# The account's Billing tab: each hosted resident's plan, a Stripe Checkout
# button per plan, plan changes and End plan, and Stripe's Customer Portal for
# cards and invoices.
# Members can see it; only the account owner can pay or change billing.
class Accounts::BillingsController < ApplicationController

  require_feature_enabled :agents
  before_action :require_account_manager!
  before_action :require_account_owner!, only: [ :checkout, :add_resident, :plan_change, :portal, :account_plan_checkout,
    :account_plan_change, :end_plan, :confirm_end_plan, :keep_plan ]

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
      pending_add: pending_add_json,
      pending_end: pending_end_json
    }
  end

  # With a live subscription, a resident joins it (Billing::Reconcile): the
  # owner is shown the quote, and confirms it with add_resident.
  def checkout
    agent = billable_agents.find(params[:agent_id])
    tier = Billing::Tier.find(params[:tier]) || raise(ActionController::BadRequest, "Unknown plan")
    rate = params[:rate].presence || "standard"
    raise ActionController::BadRequest, "Unknown rate" unless Billing::Tier::SOLD_RATES.include?(rate)

    if ResidentSubscription.live.exists?(agent: agent)
      raise Billing::AlreadySubscribed, "#{agent.name} already has a subscription; change it from Manage billing"
    end

    # An account that already pays gets one more line on its bill, quoted
    # first; otherwise Stripe's Checkout opens its first subscription.
    if Billing::Reconcile.applies?(current_account)
      change = reconcile.propose(Billing::Reconcile.add_ops(current_account, agent, tier.offer(rate)), by: Current.user)
      return redirect_to account_billing_path(current_account, add: change.id)
    end

    url = Billing::Checkout.new(
      agent: agent,
      tier: tier,
      rate: rate,
      success_url: account_billing_url(current_account, checkout: "success"),
      cancel_url: account_billing_url(current_account)
    ).url
    inertia_location url
  rescue *BILL_ERRORS => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  # Confirms a quoted addition to the bill: a resident, or the account's plan.
  def add_resident
    change = proposed_change(params[:attempt_id])
    done!(reconcile.confirm(change, digest: params[:digest].to_s))
    if (agent_id = change.ops.first["agent_id"])
      audit("add_resident_to_subscription", current_account.agents.find(agent_id), ops: change.ops,
        stripe_subscription_id: change.stripe_subscription_id)
    else
      audit("change_account_plan", current_account, ops: change.ops, stripe_subscription_id: change.stripe_subscription_id)
    end
    redirect_to account_billing_path(current_account),
      notice: "#{subject_of(change)} is on #{bought_in(change)} now. The part of this period goes on the next bill."
  rescue Billing::Reconcile::QuoteChanged => error
    requote(change, :add, error)
  rescue *BILL_ERRORS => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  def portal
    inertia_location Billing::Portal.new(account: current_account, return_url: account_billing_url(current_account)).url
  rescue Billing::NotConfigured, Billing::Portal::Restricted, Stripe::StripeError => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  # Ending one resident's plan (Billing::Reconcile): the owner is shown what
  # it does, and confirms it with confirm_end_plan.
  def end_plan
    agent = billable_agents.find(params[:agent_id])
    change = reconcile.propose_end(agent, by: Current.user)
    redirect_to account_billing_path(current_account, end: change.id)
  rescue *BILL_ERRORS => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  def confirm_end_plan
    change = proposed_change(params[:attempt_id])
    agent = billable_agents.find(change.ops.first.fetch("agent_id"))
    done!(reconcile.confirm(change, digest: params[:digest].to_s))
    audit("end_resident_plan", agent, operation: end_operation(change), stripe_subscription_id: change.stripe_subscription_id)
    redirect_to account_billing_path(current_account), notice: ended_notice(agent, change)
  rescue Billing::Reconcile::QuoteChanged => error
    requote(change, :end, error)
  rescue *BILL_ERRORS => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  def keep_plan
    agent = billable_agents.find(params[:agent_id])
    change!([ { op: "keep_bill", agent_id: agent.id } ])
    audit("keep_resident_plan", agent)
    redirect_to account_billing_path(current_account), notice: "#{agent.name}'s plan will renew as usual."
  rescue *BILL_ERRORS => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  # Moves a resident to another size at its own rate.
  def plan_change
    agent = billable_agents.find(params[:agent_id])
    tier = Billing::Tier.find(params[:tier]) || raise(ActionController::BadRequest, "Unknown plan")
    row = ResidentSubscription.live.find_by(agent: agent) ||
      raise(Billing::Reconcile::Refused, "#{agent.name} has no paid plan to change.")
    change = change!([ { op: "resize", agent_id: agent.id, price: tier.offer(row.rate).price_id } ])
    audit("change_plan", agent, tier: tier.id, rate: row.rate, stripe_subscription_id: change.stripe_subscription_id)
    redirect_to account_billing_path(current_account),
      notice: "#{agent.name} is now on #{tier.name}. Stripe puts the difference for the rest of this period on the next invoice."
  rescue *BILL_ERRORS => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  # A plan is bought with the resident it includes, never alone. An account
  # that pays already changes its plan line, quoted first; one that doesn't
  # yet chooses the plan its first bill carries, and nothing is charged now.
  def account_plan_checkout
    plan = Billing::AccountPlan.find(params[:plan]) || raise(ActionController::BadRequest, "Unknown plan")
    if Billing::Reconcile.applies?(current_account)
      change = reconcile.propose([ { op: "plan", price: plan.price_id } ], by: Current.user)
      return redirect_to account_billing_path(current_account, add: change.id)
    end

    current_account.update!(chosen_plan: plan.id)
    audit("choose_account_plan", current_account, plan: plan.id)
    redirect_to account_billing_path(current_account),
      notice: "#{plan.name} it is. It starts with your first resident, which it includes; nothing is charged until then."
  rescue *BILL_ERRORS => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  def account_plan_change
    plan = Billing::AccountPlan.find(params[:plan]) || raise(ActionController::BadRequest, "Unknown plan")
    change = change!([ { op: "plan", price: plan.price_id } ])
    audit("change_account_plan", current_account, plan: plan.id, now: current_account.reload.plan.id,
      stripe_subscription_id: change.stripe_subscription_id)
    redirect_to account_billing_path(current_account),
      notice: "The account is now on #{plan.name}. Stripe puts the difference for the rest of this period on the next invoice."
  rescue *BILL_ERRORS => error
    redirect_to account_billing_path(current_account), alert: billing_error_message(error)
  end

  private

  BILL_ERRORS = [ Billing::Reconcile::Refused, Billing::Reconcile::Uncertain, Billing::AlreadySubscribed,
                  Billing::NotConfigured, Billing::NotEligible, Billing::NotReady, Billing::InvalidSubscription,
                  Stripe::StripeError ].freeze

  def reconcile = Billing::Reconcile.new(account: current_account)

  # A change with nothing to show first: proposed and confirmed in one step.
  def change!(ops)
    change = reconcile.propose(ops, by: Current.user)
    done!(reconcile.confirm(change, digest: change.digest))
  end

  # Only an applied change is announced as done; one Stripe hasn't shown
  # yet is still being confirmed.
  def done!(change)
    change.applied? ? change : raise(Billing::NotReady, Billing::Reconcile::WAITING)
  end

  def proposed_change(id) = BillChange.where(account: current_account).find(id)

  # The quote moved: the same change is proposed again and shown again.
  def requote(change, panel, error)
    fresh = reconcile.propose(change.ops, by: Current.user)
    redirect_to account_billing_path(current_account, panel => fresh.id), alert: error.message
  rescue *BILL_ERRORS => again
    redirect_to account_billing_path(current_account), alert: billing_error_message(again)
  end

  def subject_of(change)
    op = change.ops.first
    op["agent_id"] ? current_account.agents.find(op["agent_id"]).name : "The account"
  end

  def bought_in(change)
    price = change.ops.first["price"]
    Billing::Offer.for_price(price)&.name || Billing::AccountPlan.for_price(price)&.name || "its plan"
  end

  def pending_add_json
    change = pending_change(params[:add])
    return nil unless change

    quote = change.quote
    offer = Billing::Offer.for_price(change.ops.first["price"])
    plan = change.ops.first["op"] == "plan"
    { attempt_id: change.id, digest: change.digest, kind: plan ? "plan" : "resident",
      resident_name: plan ? "the #{bought_in(change)} plan" : subject_of(change), plan: bought_in(change),
      rate: offer&.rate || "standard", currency: quote["currency"], added_cents: quote["added_next"],
      next_total_cents: quote["next_total"], recurring_cents: quote["recurring_total"],
      next_at: quote["next_at"] && Time.zone.at(quote["next_at"]).to_date.iso8601 }
  end

  def pending_end_json
    change = pending_change(params[:end])
    return nil unless change

    quote = change.quote
    at = ->(key) { quote[key] && Time.zone.at(quote[key]).to_date.iso8601 }
    { attempt_id: change.id, digest: change.digest, resident_name: subject_of(change), operation: end_operation(change),
      currency: quote["currency"], ends_at: change.ends_bill? ? at.("next_at") : nil, next_at: at.("next_at"),
      next_change_cents: quote["added_next"], next_total_cents: quote["next_total"], recurring_cents: quote["recurring_total"],
      final_total_cents: quote["final_total"] }
  end

  def pending_change(id)
    id.present? ? BillChange.unresolved.find_by(id: id, account: current_account, state: "proposed") : nil
  end

  # The names the Billing tab knows the two ways a plan ends by.
  def end_operation(change) = change.ends_bill? ? "period_end" : "delete"

  def ended_notice(agent, change)
    if change.ends_bill?
      ends = change.quote["next_at"]
      date = ends ? I18n.l(Time.zone.at(ends).to_date, format: :long) : "the end of this period"
      "#{agent.name}'s plan won't renew. #{agent.name} keeps running until #{date}."
    else
      "#{agent.name}'s plan has ended. The unused part of this period comes off the next bill as credit."
    end
  end

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
