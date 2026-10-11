# Stripe's hosted Customer Portal: card changes, invoices, plan changes and
# cancellation, with no billing UI of our own.
module Billing
  class Portal

    def initialize(account:, return_url:, client: Billing.client)
      @account = account
      @return_url = return_url
      @client = client
    end

    def url
      customer = BillingCustomer.find_by(account: @account) ||
        raise(NotConfigured, "This account has no billing details yet")
      @client.v1.billing_portal.sessions.create({ customer: customer.stripe_customer_id, return_url: @return_url }).url
    end

  end
end
