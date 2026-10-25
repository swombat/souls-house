# The card an account pays with: the Stripe customer's default payment
# method. Only what the owner needs to recognise it leaves Stripe (brand,
# last four, expiry). The card itself never touches the house.
module Billing
  class PaymentMethod

    Summary = Data.define(:id, :brand, :last4, :exp_month, :exp_year) do
      def as_json(*) = { brand: brand, last4: last4, exp_month: exp_month, exp_year: exp_year }
    end

    def initialize(account:, client: Billing.client)
      @account = account
      @client = client
    end

    # nil when the account has no customer at Stripe yet, or no saved card.
    def current
      customer = BillingCustomer.find_by(account: @account)
      return nil if customer.nil?

      remote = @client.v1.customers.retrieve(customer.stripe_customer_id,
        { expand: [ "invoice_settings.default_payment_method" ] })
      summarize(remote.invoice_settings&.default_payment_method)
    end

    # An embedded Stripe form that saves a card (and billing address) to the
    # account without charging it. Returns the session's id and the client
    # secret the browser mounts it with.
    def start_setup!
      customer = BillingCustomer.for!(@account, client: @client)
      session = @client.v1.checkout.sessions.create({
        mode: "setup",
        ui_mode: "embedded_page",
        redirect_on_completion: "never",
        currency: "usd",
        customer: customer.stripe_customer_id,
        billing_address_collection: "required",
        customer_update: { address: "auto", name: "auto" },
        tax_id_collection: { enabled: true },
        setup_intent_data: { metadata: { account_id: @account.id.to_s } }
      })
      { session_id: session.id, client_secret: session.client_secret }
    end

    # Makes the card saved by a finished setup session the account's default.
    # The session is re-read from Stripe and must be this account's own.
    def finish_setup!(session_id)
      customer = BillingCustomer.find_by!(account: @account)
      session = @client.v1.checkout.sessions.retrieve(session_id, { expand: [ "setup_intent" ] })
      unless session.mode == "setup" && stripe_id(session.customer) == customer.stripe_customer_id
        raise InvalidSubscription, "That card form belongs to another account"
      end
      raise NotReady, "The card hasn't been saved yet" unless session.status == "complete"

      payment_method = stripe_id(session.setup_intent.payment_method)
      @client.v1.customers.update(customer.stripe_customer_id,
        { invoice_settings: { default_payment_method: payment_method } })
      current
    end

    private

    def summarize(method)
      return nil if method.nil? || method.is_a?(String) || method.card.nil?

      Summary.new(id: method.id, brand: method.card.brand, last4: method.card.last4,
        exp_month: method.card.exp_month, exp_year: method.card.exp_year)
    end

    def stripe_id(value)
      value.respond_to?(:id) ? value.id : value
    end

  end
end
