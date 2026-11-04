# Redeeming a billing code on the account, from the Billing tab's "Have a
# code?" box. Owner only. Redeeming changes nothing by itself: it changes what
# the account is offered from then on.
class Accounts::BillingCodesController < ApplicationController

  require_feature_enabled :agents
  before_action :require_account_owner!

  def create
    redemption = BillingCode.redeem!(code: params.require(:code), account: current_account, by: Current.user)
    audit("redeem_billing_code", redemption, code: redemption.billing_code.code, effect: redemption.effect)
    redirect_to account_billing_path(current_account), notice: accepted(redemption)
  rescue BillingCode::Refused, ActionController::ParameterMissing => error
    redirect_to account_billing_path(current_account), alert: error.message
  end

  private

  def accepted(redemption)
    case redemption.effect
    when "at_cost"
      "Code accepted. This account can now buy plans at cost: the machine's price, with no house-model allowance."
    else
      "Code accepted."
    end
  end

end
