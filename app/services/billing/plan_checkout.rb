module Billing
  # An account plan bought by itself, as the account's first bill (jGgWgj):
  # Partners to invite someone before there is any resident, say. Stripe
  # Checkout in subscription mode, one line: the plan's price, quantity one.
  # An account that already pays a bill puts the plan on it instead
  # (Billing::Reconcile, quoted on the Billing tab).
  #
  # Like a resident's Checkout (Billing::Checkout) it grants nothing. The
  # attempt (AccountPlanCheckoutAttempt, one unresolved per account) is
  # committed before Stripe is asked, and its session is replayed or expired
  # by the same rules (Billing::CheckoutSession). It holds the account's
  # first bill while it could still be paid (Billing::FirstBill), so no other
  # opener starts a second one beside it. The paid subscription comes into
  # the house through BillSync#adopt!, which resolves the attempt.
  class PlanCheckout

    OPERATION_BUDGET = Checkout::OPERATION_BUDGET

    def initialize(account:, plan:, success_url:, cancel_url:, client: Billing.client)
      @account, @plan, @client = account, plan, client
      @success_url, @cancel_url = success_url, cancel_url
    end

    def url
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + OPERATION_BUDGET
      CheckoutLock.synchronize_residents(@account) do
        FirstBill.relink!(@account, client: @client)
        if Reconcile.applies?(@account)
          raise AlreadySubscribed, "This account already pays a bill; add the plan to it from the Billing tab."
        end
        raise NotConfigured, "The #{@plan.name} plan has no Stripe price configured" unless @plan.purchasable?
        if (given = @account.given_plan) && given >= @plan
          raise NotEligible, "The account already has the #{given.name} plan, with nothing to pay for it."
        end

        Checkout.release_expired!(@account, client: @client)
        FirstBill.refuse_if_waiting!(@account, error: AlreadySubscribed, except_plan_checkout: true)
        customer = remote { BillingCustomer.for!(@account, client: @client) }

        attempt = AccountPlanCheckoutAttempt.unresolved.find_by(account: @account)
        if attempt
          session = recover!(attempt)
          next session.url if attempt.plan == @plan.id && session.status == "open" && session.url.present?

          settle!(session)
          attempt.update!(resolved_at: Time.current)
        end

        key = "souls-house-plan-checkout-#{SecureRandom.uuid}"
        # No surrounding transaction: this write has committed when create runs.
        attempt = AccountPlanCheckoutAttempt.create!(account: @account, plan: @plan.id, stripe_price_id: @plan.price_id,
          idempotency_key: key, create_params: params(customer, key))
        session = recover!(attempt, first_send: true)
        raise NotReady, "This Checkout is no longer open. Please try again." unless session.status == "open" && session.url.present?

        session.url
      end
    end

    private

    def recover!(attempt, first_send: false)
      CheckoutSession.recover!(attempt, client: @client, remote: method(:remote),
        stale: "An earlier Checkout for this account's plan needs operator reconciliation. " \
               "Contact #{Billing.contact_email}; do not pay another link.")
    rescue Stripe::InvalidRequestError => error
      raise unless first_send && CheckoutSession.rejected?(attempt, error)

      # Stripe refused this attempt's first and only send outright, so there
      # is no session to pay or recover. A 400 on a replay proves nothing
      # about an earlier send that had no answer, so that attempt stays
      # pinned (Mira, #1149). The attempt stops holding the first bill and the next try
      # is a new attempt, with whatever was corrected (Mira, #1149).
      attempt.update!(resolved_at: Time.current)
      Rails.error.report(error, handled: true, context: { subsystem: "billing", plan_checkout_attempt_id: attempt.id })
      raise NotReady, "Stripe refused this Checkout, and nothing was charged. Please try again later, " \
                      "or contact #{Billing.contact_email}."
    end

    # An earlier session for this account's plan, before a new one replaces
    # it: an open one is closed so it can't be paid as well; a completed one
    # means a plan is paid for, or its payment is still being decided, unless
    # Stripe has ended its subscription unpaid (CheckoutSession.ended_unpaid?).
    def settle!(session)
      case session.status
      when "open"
        CheckoutSession.expire!(session, client: @client, remote: method(:remote))
      when "complete"
        unless remote { CheckoutSession.ended_unpaid?(session, client: @client) }
          raise AlreadySubscribed, "A payment for this account's plan is still being confirmed by Stripe. " \
                                   "It goes onto the account once it has."
        end
      when "expired"
        # Safe to replace.
      else
        raise NotReady, "Stripe hasn't confirmed the earlier Checkout's state. Please try again."
      end
    end

    def params(customer, key)
      metadata = { kind: "account_plan", plan: @plan.id, account_id: @account.id.to_s, plan_checkout_attempt: key }
      {
        # Card only: a card pays the first invoice before Checkout completes,
        # so the subscription is never active unpaid. A delayed method can
        # make it active before its payment clears (Mira, #1149). Stripe's
        # API (2026-09-30.endive on) refuses payment_method_types on a
        # Checkout Session; allowed_payment_method_types is its successor.
        mode: "subscription", allowed_payment_method_types: [ "card" ],
        customer: customer.stripe_customer_id, client_reference_id: "account-#{@account.id}",
        line_items: [ { price: @plan.price_id, quantity: 1 } ],
        subscription_data: { metadata: metadata, description: "#{@plan.name} plan" },
        metadata: metadata, automatic_tax: { enabled: true }, tax_id_collection: { enabled: true },
        billing_address_collection: "required", customer_update: { address: "auto", name: "auto" },
        success_url: @success_url, cancel_url: @cancel_url
      }
    end

    def remote
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @deadline
        raise NotReady, "Stripe is taking too long. Your Checkout is kept; please try again."
      end
      yield
    end

  end
end
