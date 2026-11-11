# Stripe's hosted Customer Portal: card changes and invoices, with no billing
# UI of our own.
#
# Every session names a configuration read from Stripe just before the
# session is made and found safe: active, cancellation and plan switching
# explicitly off, card update and invoice history explicitly on. Residents
# share one subscription (one item each, eoXAEj), and any account with a live
# subscription can gain a second resident, so a session that can cancel is
# never safe to hand out: cancelling there would end every resident on the
# bill, including ones added after the page was opened. A flag Stripe doesn't
# send counts as unsafe. With no safe configuration no session is made, never
# one on Stripe's default. Ending and changing a resident's plan happen on
# the Billing tab.
module Billing
  class Portal

    # Manage billing can't be offered safely right now.
    class Restricted < StandardError; end

    def initialize(account:, return_url:, client: Billing.client)
      @account = account
      @return_url = return_url
      @client = client
    end

    def url
      customer = BillingCustomer.find_by(account: @account) ||
        raise(NotConfigured, "This account has no billing details yet")
      configuration = self.class.safe_configuration_id(@client) ||
        raise(Restricted, "Manage billing is closed for a moment while it is made safe for bills several residents " \
                          "share. To change a card or get an invoice, write to #{Billing.contact_email}.")
      @client.v1.billing_portal.sessions.create({ customer: customer.stripe_customer_id, return_url: @return_url,
                                                  configuration: configuration }).url
    end

    def self.safe?(configuration)
      features = configuration[:features]
      flag = ->(name) { features.respond_to?(:[]) && features[name].respond_to?(:[]) ? features[name][:enabled] : nil }
      configuration[:active] == true && flag.(:subscription_cancel) == false && flag.(:subscription_update) == false &&
        flag.(:payment_method_update) == true && flag.(:invoice_history) == true
    end

    # The first safe configuration, read from Stripe now; nil when none is,
    # or when the listing ends early.
    def self.safe_configuration_id(client)
      starting_after = nil
      loop do
        page = client.v1.billing_portal.configurations.list({ limit: 100, starting_after: starting_after }.compact)
        found = page.data.find { |configuration| safe?(configuration) }
        return found.id if found
        return nil unless page[:has_more] && page.data.any?

        starting_after = page.data.last.id
      end
    end

  end
end
