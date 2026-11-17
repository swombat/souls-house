# Site Admin → Billing codes: make, revoke and watch codes, and withdraw an
# account's grant. Revoking a code stops new redemptions and nothing else;
# withdrawing a redemption stops that account's future purchases at the rate
# and never touches a subscription already bought.
class Admin::BillingCodesController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  def index
    render inertia: "admin/billing-codes", props: {
      effects: BillingCode::EFFECTS,
      effect_labels: BillingCode::EFFECTS.index_with { |effect| BillingCode.label(effect) },
      codes: BillingCode.includes(:created_by).by_recency.map(&:as_json),
      redemptions: BillingCodeRedemption.includes(:billing_code, :account, :redeemed_by).order(redeemed_at: :desc)
        .limit(200).map(&:as_json)
    }
  end

  def create
    attributes = params.require(:billing_code).permit(:code, :effect, :max_redemptions, :expires_at, :note)
    code = BillingCode.new(attributes.merge(created_by: Current.user))
    code.code = BillingCode.generate if code.code.blank?
    if code.save
      audit("create_billing_code", code, code: code.code, effect: code.effect, max_redemptions: code.max_redemptions)
      redirect_to admin_billing_codes_path, notice: "Code #{code.code} made."
    else
      redirect_to admin_billing_codes_path, inertia: { errors: code.errors.to_hash }
    end
  end

  def revoke
    code = BillingCode.find(params[:id])
    code.revoke!
    audit("revoke_billing_code", code, code: code.code)
    redirect_to admin_billing_codes_path, notice: "Code #{code.code} withdrawn. Grants already made stay."
  end

  def withdraw
    redemption = BillingCodeRedemption.find(params[:id])
    redemption.withdraw!(by: Current.user)
    audit("withdraw_billing_code_redemption", redemption, code: redemption.billing_code.code,
      account_id: redemption.account_id)
    withdrawn = "#{redemption.account.name} no longer holds: #{BillingCode.label(redemption.effect)}."
    change = (Billing::PlanAfterGrant.restore!(redemption.account, by: Current.user) if redemption.effect.start_with?("plan:"))
    redirect_to admin_billing_codes_path, notice: [ withdrawn, plan_notice(redemption.account, change) ].join(" ")
  rescue *PLAN_ERRORS => error
    redirect_to admin_billing_codes_path,
      alert: "#{withdrawn} Its plan couldn't be put on its bill yet (#{error.message}); the house retries this until it can."
  end

  private

  PLAN_ERRORS = [ Billing::Reconcile::Refused, Billing::Reconcile::QuoteChanged, Billing::Reconcile::Uncertain,
                  Billing::NotReady, Billing::NotEligible, Billing::NotConfigured, Billing::AlreadySubscribed,
                  Stripe::StripeError ].freeze

  def plan_notice(account, change)
    return "Plans already bought are unchanged." unless change

    plan = Billing::AccountPlan.for_price(change.ops.first["price"])
    audit("bill_plan_after_grant", account, plan: plan.id, bill_change_id: change.id, applied: change.applied?)
    if change.applied?
      "Its bill now carries #{plan.name}, #{Billing.usd_label(plan.monthly_usd)} a month; the resident it includes keeps its price."
    else
      "#{plan.name} is being added to its bill; Stripe is still confirming."
    end
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
