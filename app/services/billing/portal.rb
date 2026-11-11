# Stripe's hosted Customer Portal: card changes, invoices, plan changes and
# cancellation, with no billing UI of our own.
#
# A subscription that carries several residents (one item each, eoXAEj) must
# never be opened on a configuration that can cancel or switch it: cancelling
# there ends every resident on the bill at once. Such an account gets a
# session only on a configuration read just before the session is made and
# found safe (cancellation and plan switching off, card and invoices on).
# With none, or when the customer's subscriptions can't be read, no session
# is made. A configuration nobody uses proves nothing, so the check is on the
# one the session names.
module Billing
  class Portal

    # Manage billing can't be offered safely to this account right now.
    class Restricted < StandardError; end

    ENDED = %w[canceled incomplete_expired].freeze

    def initialize(account:, return_url:, client: Billing.client)
      @account = account
      @return_url = return_url
      @client = client
    end

    def url
      customer = BillingCustomer.find_by(account: @account) ||
        raise(NotConfigured, "This account has no billing details yet")
      params = { customer: customer.stripe_customer_id, return_url: @return_url }
      if shared?(customer.stripe_customer_id)
        params[:configuration] = self.class.safe_configuration_id(@client) || raise(Restricted, restricted_message)
      end
      @client.v1.billing_portal.sessions.create(params).url
    end

    # A configuration a shared bill may be opened on: active, nothing that
    # cancels or switches a subscription, and a card can be added and
    # invoices read.
    def self.safe?(configuration)
      features = configuration[:features] || {}
      enabled = ->(name) { features[name].respond_to?(:[]) && features[name][:enabled] == true }
      configuration[:active] == true && !enabled.(:subscription_cancel) && !enabled.(:subscription_update) &&
        enabled.(:payment_method_update) && enabled.(:invoice_history)
    end

    # The first safe configuration, read from Stripe now; nil when none is.
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

    private

    # Whether any of the customer's subscriptions that hasn't ended carries
    # more than one item. Every page is read; an error propagates, so an
    # unreadable account never falls through to the default configuration.
    def shared?(customer_id)
      starting_after = nil
      loop do
        page = @client.v1.subscriptions.list({ customer: customer_id, status: "all", limit: 100,
                                               starting_after: starting_after }.compact)
        return true if page.data.any? { |subscription| several_items?(subscription) }
        return false unless page[:has_more] && page.data.any?

        starting_after = page.data.last.id
      end
    end

    def several_items?(subscription)
      return false if subscription.status.in?(ENDED)

      items = subscription[:items]
      items.nil? || items[:has_more] || items.data.size > 1
    end

    def restricted_message
      "Manage billing is closed for now on a bill shared by several residents, because Stripe's page could end " \
        "all of them at once. To change a card or get an invoice, write to #{Billing.contact_email}."
    end

  end
end
