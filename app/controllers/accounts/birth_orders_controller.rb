# The creation wizard's last step in an account that pays per resident:
# start the plan's subscription for the drafted resident, pay its first
# invoice in the browser with Stripe.js, then confirm. The resident is born
# on confirmation (or by the webhook, whichever is first) once Stripe says
# the plan is paid. JSON, because the browser needs Stripe's client secret.
class Accounts::BirthOrdersController < ApplicationController

  include AgentSettingsParams

  require_feature_enabled :agents
  before_action :require_account_owner!
  before_action :set_order, only: %i[payment confirm]

  rescue_from Billing::PaidBirth::Refused, Agents::HostedProvisioning::ConfigurationError, Billing::NotConfigured do |error|
    render json: { error: error.message }, status: :unprocessable_entity
  end
  # An uncertain answer from Stripe: the order and its draft are kept, and the
  # browser retries the same order through its payment URL.
  rescue_from Billing::PaidBirth::Uncertain do |error|
    render json: { error: error.message, order: error.order.as_json,
                   payment_url: payment_account_birth_order_path(current_account, error.order),
                   confirm_url: confirm_account_birth_order_path(current_account, error.order) },
      status: :service_unavailable
  end
  rescue_from Stripe::StripeError do |error|
    Rails.error.report(error, handled: true, context: { subsystem: "billing" })
    render json: { error: "Stripe couldn't complete that just now. Please try again." }, status: :bad_gateway
  end

  def create
    attrs = birth_params.to_h.symbolize_keys
    open_beginning = ActiveModel::Type::Boolean.new.cast(attrs.delete(:open_beginning))
    attrs[:system_prompt] = "" if open_beginning
    tier = Billing::Tier.find(params.require(:tier)) || raise(Billing::PaidBirth::Refused, "Choose a plan.")
    return if provider_key_refused?

    order, client_secret, payment_method_id = Billing::PaidBirth.new.start!(account: current_account,
      creator: Current.user, attributes: attrs, open_beginning: open_beginning, tier: tier)
    audit("start_paid_birth", order, tier: tier.id, resident_name: order.resident_name)
    render json: payment_json(order, client_secret, payment_method_id), status: :created
  end

  # A fresh secret to pay again, after a decline or with a different card.
  def payment
    result = Billing::PaidBirth.new.payment(@order)
    if result[:paid]
      render json: payment_json(@order, nil, nil).merge(paid: true)
    else
      render json: payment_json(@order, result[:client_secret], result[:payment_method_id])
    end
  end

  def confirm
    Billing::PaidBirth.new.complete!(@order)
    render json: confirmation_json
  rescue ActiveRecord::RecordInvalid, Agents::HostedProvisioning::ConfigurationError
    render json: confirmation_json, status: :unprocessable_entity
  end

  private

  def set_order
    @order = current_account.resident_birth_orders.where(creator: Current.user).find(params[:id])
  end

  def payment_json(order, client_secret, payment_method_id)
    { order: order.as_json, client_secret: client_secret, payment_method_id: payment_method_id,
      payment_url: payment_account_birth_order_path(current_account, order),
      confirm_url: confirm_account_birth_order_path(current_account, order) }
  end

  def confirmation_json
    @order.reload
    { order: @order.as_json,
      redirect_to: @order.born? ? onboarding_account_agent_path(current_account, @order.agent) : nil }
  end

  # The wizard can carry a provider key pasted on its Runtime step; it is
  # saved to the account before payment, exactly as an unpaid birth saves it.
  def provider_key_refused?
    key = params.fetch(:provider_key, {}).permit(:provider, :value)
    value = key[:value].to_s.strip
    return false if value.blank?

    provider = key[:provider].to_s
    unless Account::AI_PROVIDERS.key?(provider.to_sym)
      render json: { error: "Unknown model provider" }, status: :unprocessable_entity
      return true
    end
    current_account.update_ai_api_keys!(set: { provider => value })
    audit("update_agent_api_keys", current_account, provider: provider, source: "new_resident")
    false
  end

end
