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
    restored = Billing::PlanAfterGrant.restore!(redemption.account, by: Current.user)
    plan = restored && redemption.account.plan_to_pay_for
    redirect_to admin_billing_codes_path,
      notice: "#{redemption.account.name} no longer holds: #{BillingCode.label(redemption.effect)}. " +
        (plan ? "Its bill now carries #{plan.name} again, at #{Billing.usd_label(plan.monthly_usd)} a month; its included resident stays at no charge." :
          "Plans already bought are unchanged.")
  rescue Billing::Reconcile::Refused, Billing::Reconcile::Uncertain, Billing::NotReady, Stripe::StripeError => error
    redirect_to admin_billing_codes_path,
      alert: "The grant is withdrawn, but the plan couldn't be put back on #{redemption.account.name}'s bill: #{error.message}"
  end

  private

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
