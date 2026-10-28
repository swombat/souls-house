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
    redirect_to admin_billing_codes_path,
      notice: "#{redemption.account.name} can no longer buy at #{redemption.effect.humanize.downcase}. Plans already bought are unchanged."
  end

  private

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
