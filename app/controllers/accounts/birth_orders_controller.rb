# The creation wizard's last step in an account that pays per resident:
# start the plan's subscription for the drafted resident, pay its first
# invoice in the browser with Stripe.js, then confirm. The resident is born
# on confirmation (or by the webhook, whichever is first) once Stripe says
# the plan is paid. JSON, because the browser needs Stripe's client secret.
#
# In an account that already has a live subscription the order is an item
# order: create answers with the quote (item_quote) instead of a secret, the
# owner confirms it (confirm_item), and the resident is added to the
# account's bill and born; nothing is charged in the browser.
class Accounts::BirthOrdersController < ApplicationController

  include AgentSettingsParams

  require_feature_enabled :agents
  before_action :require_account_owner!
  before_action :set_order, only: %i[payment confirm confirm_item trial_return]

  rescue_from Billing::PaidBirth::Refused, Agents::HostedProvisioning::ConfigurationError, Billing::NotConfigured,
    Billing::NotEligible, Billing::ItemQuote::Refused do |error|
    render json: { error: error.message }, status: :unprocessable_entity
  end
  rescue_from Billing::NotReady do |error|
    render json: { error: error.message }, status: :service_unavailable
  end
  # The quote moved before anything was sent: the new one, to confirm again.
  rescue_from Billing::PaidBirth::QuoteChanged do |error|
    render json: { error: error.message, item_quote: item_quote_json(error.order) }, status: :conflict
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
    rate = params[:rate].presence || "standard"
    raise Billing::PaidBirth::Refused, "Choose a plan." unless Billing::Tier::RATES.include?(rate)
    return if provider_key_refused?
    return create_trial(attrs, open_beginning, tier, rate) if ActiveModel::Type::Boolean.new.cast(params[:trial])

    order, client_secret, payment_method_id = Billing::PaidBirth.new.start!(account: current_account,
      creator: Current.user, attributes: attrs, open_beginning: open_beginning, tier: tier, rate: rate)
    audit("start_paid_birth", order, tier: tier.id, rate: rate, resident_name: order.resident_name, kind: order.kind)
    render json: payment_json(order, client_secret, payment_method_id), status: :created
  end

  # The owner confirms an item order's quote: the resident is added to the
  # account's subscription, then born. The browser then polls confirm.
  def confirm_item
    Billing::PaidBirth.new.confirm_item!(@order, digest: params[:digest])
    audit("confirm_item_birth", @order, resident_name: @order.resident_name)
    render json: payment_json(@order.reload, nil, nil).merge(accepted: true)
  end

  # A fresh secret to pay again, after a decline or with a different card.
  def payment
    result = Billing::PaidBirth.new.payment(@order)
    if result[:accepted]
      render json: payment_json(@order.reload, nil, nil).merge(accepted: true)
    elsif result[:paid]
      render json: payment_json(@order, nil, nil).merge(paid: true)
    elsif result[:checkout_url]
      render json: payment_json(@order, nil, nil).merge(checkout_url: result[:checkout_url])
    else
      render json: payment_json(@order, result[:client_secret], result[:payment_method_id])
    end
  end

  # Stripe's free-trial Checkout sends the browser back here. The resident is
  # born now if Stripe says the trial started (or by the webhook, whichever
  # is first).
  def trial_return
    Billing::PaidBirth.new.complete!(@order) if @order.trial?
    @order.reload
    if @order.born?
      redirect_to onboarding_account_agent_path(current_account, @order.agent)
    else
      redirect_to new_account_agent_path(current_account),
        notice: "Stripe is confirming the free trial. #{@order.resident_name} will appear with your residents in a moment."
    end
  rescue ActiveRecord::RecordInvalid, Agents::HostedProvisioning::ConfigurationError, Stripe::StripeError => error
    Rails.error.report(error, handled: true, context: { subsystem: "billing", birth_order_id: @order.id })
    redirect_to new_account_agent_path(current_account),
      alert: "#{@order.resident_name} couldn't be created just yet. Nothing was charged; try again in a moment."
  end

  def confirm
    Billing::PaidBirth.new.complete!(@order)
    render json: confirmation_json
  rescue ActiveRecord::RecordInvalid, Agents::HostedProvisioning::ConfigurationError
    render json: confirmation_json, status: :unprocessable_entity
  end

  private

  # The free trial (Billing::Trial): a small resident at the standard rate,
  # no card. The browser goes to checkout_url.
  def create_trial(attrs, open_beginning, tier, rate)
    unless tier.id == Billing::Trial::TIER && rate == Billing::Trial::RATE
      raise Billing::PaidBirth::Refused, "The free trial is for a small resident."
    end

    order, checkout_url = Billing::PaidBirth.new.start_trial!(account: current_account, creator: Current.user,
      attributes: attrs, open_beginning: open_beginning,
      success_url: ->(order) { trial_return_account_birth_order_url(current_account, order) },
      cancel_url: new_account_agent_url(current_account))
    audit("start_trial_birth", order, tier: tier.id, rate: rate, resident_name: order.resident_name)
    render json: payment_json(order, nil, nil).merge(checkout_url: checkout_url), status: :created
  end

  def set_order
    @order = current_account.resident_birth_orders.where(creator: Current.user).find(params[:id])
  end

  def payment_json(order, client_secret, payment_method_id)
    json = { order: order.as_json, client_secret: client_secret, payment_method_id: payment_method_id,
             payment_url: payment_account_birth_order_path(current_account, order),
             confirm_url: confirm_account_birth_order_path(current_account, order) }
    if order.item?
      json[:confirm_item_url] = confirm_item_account_birth_order_path(current_account, order)
      json[:item_quote] = item_quote_json(order) unless order.item_submitted_at?
    end
    json
  end

  # The quote as the wizard shows it; digest is what confirm_item checks.
  def item_quote_json(order)
    quote = order.item_quote.to_h
    { digest: Billing::ItemQuote.digest(quote), currency: quote["currency"], added_cents: quote["added_next"],
      next_total_cents: quote["next_total"], recurring_cents: quote["recurring_total"],
      next_at: quote["next_at"] && Time.zone.at(quote["next_at"]).to_date.iso8601 }
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
