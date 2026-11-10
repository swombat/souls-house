# Stripe Checkout for an account's plan (Billing::AccountPlan): one line item,
# metadata kind=account_plan, the same tax and address settings as a
# resident's Checkout. It grants nothing: the plan comes in when
# AccountSubscriptionSync brings the paid subscription in.
#
# The discipline is Billing::Checkout's: under a session lock on the account
# (the key AccountSubscriptionSync takes), refuse if a plan is live; an
# attempt is committed before Stripe is called and replayed under its own
# idempotency key, so an uncertain create can't make a second payable
# session; one unresolved attempt per account.
module Billing
  class AccountPlanCheckout

    class Refused < StandardError; end

    REPLAY_WINDOW = Checkout::REPLAY_WINDOW

    def initialize(account:, plan:, success_url:, cancel_url:, client: Billing.client)
      @account, @plan, @client = account, plan, client
      @success_url, @cancel_url = success_url, cancel_url
    end

    def url
      raise Refused, "Companions comes with every account; there is nothing to buy." if @plan.free?

      CheckoutLock.synchronize_account(@account) do
        if @account.account_subscriptions.live.exists?
          raise AlreadySubscribed, "This account already has a plan; change it from the Billing tab or Manage billing."
        end
        raise NotConfigured, "The #{@plan.name} plan has no Stripe price configured" unless @plan.purchasable?

        customer = BillingCustomer.for!(@account, client: @client)
        attempt = AccountPlanCheckoutAttempt.unresolved.find_by(account: @account)
        if attempt
          session = recover!(attempt)
          next session.url if attempt.plan == @plan.id && session.status == "open" && session.url.present?

          settle!(session)
          attempt.update!(resolved_at: Time.current)
        end

        key = "souls-house-account-plan-checkout-#{SecureRandom.uuid}"
        payload = params(customer, key)
        # No surrounding transaction: this write has committed when create runs.
        attempt = AccountPlanCheckoutAttempt.create!(account: @account, plan: @plan.id,
          stripe_price_id: @plan.price_id, idempotency_key: key, create_params: payload)
        session = recover!(attempt)
        raise NotReady, "This Checkout is no longer open. Please try again." unless session.status == "open" && session.url.present?

        session.url
      end
    end

    private

    def recover!(attempt)
      return @client.v1.checkout.sessions.retrieve(attempt.stripe_session_id) if attempt.stripe_session_id?
      if attempt.created_at < REPLAY_WINDOW.ago
        raise NotReady, "An earlier Checkout for this account's plan needs operator reconciliation. " \
                        "Contact #{Billing.contact_email}; do not pay another link."
      end

      session = @client.v1.checkout.sessions.create(attempt.create_params.deep_symbolize_keys,
        { idempotency_key: attempt.idempotency_key })
      attempt.update!(stripe_session_id: session.id)
      # A replay can return the cached open response after the session ended.
      @client.v1.checkout.sessions.retrieve(session.id)
    end

    def settle!(session)
      case session.status
      when "open"
        expired = @client.v1.checkout.sessions.expire(session.id)
        raise NotReady, "The earlier Checkout could not be expired. Please try again." unless expired.status == "expired"
      when "complete"
        recorded = AccountSubscription.find_by(stripe_subscription_id: stripe_id(session.subscription), account: @account)
        if recorded.nil? || recorded.live?
          raise AlreadySubscribed, "A payment for this account's plan is still being confirmed by Stripe. Try again in a minute."
        end
      when "expired"
        # Safe to replace.
      else
        raise NotReady, "Stripe hasn't confirmed the earlier Checkout's state. Please try again."
      end
    end

    def params(customer, key)
      metadata = { kind: AccountSubscriptionSync::KIND, account_id: @account.id.to_s, plan: @plan.id, checkout_attempt: key }
      {
        mode: "subscription", customer: customer.stripe_customer_id, client_reference_id: "account-#{@account.id}",
        line_items: [ { price: @plan.price_id, quantity: 1 } ],
        subscription_data: { metadata: metadata, description: "#{@plan.name} plan for #{@account.name}" },
        metadata: metadata, automatic_tax: { enabled: true }, tax_id_collection: { enabled: true },
        billing_address_collection: "required", customer_update: { address: "auto", name: "auto" },
        success_url: @success_url, cancel_url: @cancel_url
      }
    end

    def stripe_id(value) = value.respond_to?(:id) ? value.id : value

  end
end
