# Redeeming a billing code on the account, from the Billing tab's "Have a
# code?" box. Owner only. Redeeming changes nothing by itself: it changes what
# the account is offered from then on.
class Accounts::BillingCodesController < ApplicationController

  require_feature_enabled :agents
  before_action :require_account_owner!

  def create
    # A first-bill Checkout Stripe has expired no longer holds a plan code back.
    Billing::Checkout.release_expired!(current_account)
    redemption = BillingCode.redeem!(code: params.require(:code), account: current_account, by: Current.user)
    audit("redeem_billing_code", redemption, code: redemption.billing_code.code, effect: redemption.effect)
    redirect_to account_billing_path(current_account), notice: accepted(redemption)
  rescue BillingCode::Refused, ActionController::ParameterMissing, Billing::AlreadySubscribed, Billing::NotReady,
         Stripe::StripeError => error
    redirect_to account_billing_path(current_account), alert: error.message
  end

  private

  def accepted(redemption)
    if (plan = BillingCode.plan_of(redemption.effect))
      "Code accepted. This account is on the #{plan.name} plan, with nothing to pay for it."
    elsif (size = redemption.effect.split(":", 2).second)
      "Code accepted. This account can now buy a #{Billing::Tier.find!(size).name} at cost: the machine's price, " \
        "with no house-model allowance."
    else
      "Code accepted. This account can now buy plans at cost: the machine's price, with no house-model allowance."
    end
  end

end
