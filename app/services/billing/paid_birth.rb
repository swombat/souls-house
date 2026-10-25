# Paying for a resident as the last step of creating it, in an account that
# pays per resident (Daniel, oewbQY 2026-10-25).
#
# One ResidentBirthOrder is the identity of one paid creation, from the first
# click to the born resident; every step below can be repeated safely, by the
# browser or by the webhook, in any order:
#
#   start!       records the draft as an order, then opens the plan's
#                subscription at Stripe (first invoice open). The Stripe call
#                carries an idempotency key per order, so an uncertain answer
#                (timeout, network) is retried with the same key and finds the
#                same subscription; the order and its draft are kept meanwhile.
#   payment      the client secret to pay the order's first invoice, opening
#                the subscription if that never succeeded. If the invoice is
#                already paid it completes the order instead, so a retry after
#                payment never pays twice.
#   complete!    once Stripe says the subscription is paid: (1) bears the
#                resident through the ordinary birth, committed locally, then
#                (2) links it: names the committed resident on the
#                subscription and brings the subscription in. Stripe only ever
#                names a resident that exists. If linking fails it is retried
#                by the next confirm or webhook; a born order is linked again
#                until its plan is in force.
#
# Nothing is born before money has cleared. A paid order is never replaced by
# a new one: asking to create another resident while one is paid finishes the
# paid one and says so. Unpaid orders are abandoned by the sweeper after
# expires_at, their subscriptions cancelled and drafts cleared.
module Billing
  class PaidBirth

    class Refused < StandardError; end

    # Raised when the Stripe call that opens an order's subscription had no
    # certain answer. The order and its draft are kept; payment retries it.
    class Uncertain < StandardError

      attr_reader :order

      def initialize(order, message = "Stripe didn't answer in time. Your draft is kept; try again.")
        @order = order
        super(message)
      end

    end

    PAID = ResidentSubscription::PAID_STATUSES

    def initialize(client: Billing.client)
      @client = client
    end

    # Returns [order, client_secret, payment_method_id].
    def start!(account:, creator:, attributes:, open_beginning:, tier:)
      refuse!(account, creator, tier)
      payment_method = current_payment_method!(account)
      Agents::VmBirthPolicy.current.refuse!(kind: :birth)
      raise Refused, "Give the resident a name first." if attributes[:name].to_s.strip.empty?
      if attributes[:system_prompt].to_s.strip.empty? && !open_beginning
        raise Refused, "Write a soul seed, or choose an open beginning."
      end

      settle_earlier!(account, creator)
      order = ResidentBirthOrder.create!(account: account, creator: creator, tier: tier.id,
        birth_attributes: attributes.to_h, open_beginning: open_beginning)
      subscription = open_subscription!(order, payment_method)
      [ order, client_secret(subscription), payment_method.id ]
    end

    # Returns { client_secret:, payment_method_id: } to pay the first invoice,
    # or { paid: true } when it is already paid (the order is completed).
    def payment(order)
      raise Refused, "This resident is no longer waiting for payment." unless order.pending? || order.failed?

      if order.stripe_subscription_id.present?
        remote = @client.v1.subscriptions.retrieve(order.stripe_subscription_id)
        if remote.status.in?(PAID)
          complete!(order)
          return { paid: true }
        end
      end
      raise Refused, "This resident is no longer waiting for payment." unless order.pending?

      payment_method = current_payment_method!(order.account)
      remote_subscription(order) if order.stripe_subscription_id.blank?
      subscription = if order.stripe_subscription_id.present?
        @client.v1.subscriptions.update(order.stripe_subscription_id,
          { default_payment_method: payment_method.id, expand: [ "latest_invoice.confirmation_secret" ] })
      else
        open_subscription!(order, payment_method)
      end
      { client_secret: client_secret(subscription), payment_method_id: payment_method.id }
    end

    # Returns the order: born (and linked) once its subscription is paid.
    def complete!(order)
      bear_if_paid!(order)
      link!(order.reload) if order.born?
      order
    end

    # The sweeper's: an order still unpaid at expires_at is abandoned. One
    # paid at the last moment is born instead.
    def abandon_expired!(order)
      abandoned = order.with_lock do
        next false unless order.pending?

        remote = remote_subscription(order)
        next false if remote && remote.status.in?(PAID)

        @client.v1.subscriptions.cancel(remote.id) if remote && remote.status == "incomplete"
        order.update!(state: "abandoned", birth_attributes: {})
        true
      end
      complete!(order) unless abandoned
      order
    end

    private

    def refuse!(account, creator, tier)
      raise Refused, "This account doesn't pay per resident." unless account.billing_required?
      raise Refused, "Only the account's owner can pay for a new resident." unless account.owned_by?(creator)
      raise Refused, "Paying for residents isn't open on this house yet." unless Billing.configured?
      raise Refused, "That plan can't be bought yet." unless tier&.purchasable?
    end

    def current_payment_method!(account)
      PaymentMethod.new(account: account, client: @client).current ||
        raise(Refused, "Add a card to pay for the plan first.")
    end

    # Opens (or, after an uncertain answer, finds again through the same
    # idempotency key) the order's subscription. Stripe's answer is recorded
    # before anything else can happen to the order.
    def open_subscription!(order, payment_method)
      tier = order.tier_record
      customer = BillingCustomer.find_by!(account: order.account)
      subscription = @client.v1.subscriptions.create({
        customer: customer.stripe_customer_id,
        items: [ { price: tier.price_id } ],
        default_payment_method: payment_method.id,
        payment_behavior: "default_incomplete",
        payment_settings: { save_default_payment_method: "on_subscription" },
        automatic_tax: { enabled: true },
        description: "#{tier.name} hosting for #{order.resident_name}",
        metadata: { birth_order_id: order.id.to_s, account_id: order.account_id.to_s, tier: tier.id },
        expand: [ "latest_invoice.confirmation_secret" ]
      }, { idempotency_key: "souls-house-birth-order-#{order.id}" })
      order.update!(stripe_subscription_id: subscription.id, last_error: nil)
      subscription
    rescue Stripe::APIConnectionError, Stripe::APIError, Stripe::RateLimitError => error
      order.update!(last_error: "Opening the subscription: #{error.class.name.demodulize}")
      raise Uncertain.new(order)
    end

    # One open order per person and account. An earlier unpaid one is
    # replaced (its subscription cancelled). An earlier paid one is never
    # replaced: it is completed, and the new request is refused, so nobody
    # pays twice for one intention.
    def settle_earlier!(account, creator)
      ResidentBirthOrder.where(account: account, creator: creator, state: %w[pending failed]).find_each do |earlier|
        remote = remote_subscription(earlier)
        if (remote && remote.status.in?(PAID)) || earlier.failed?
          name = earlier.resident_name
          begin
            complete!(earlier)
          rescue StandardError => error
            Rails.error.report(error, handled: true, context: { subsystem: "billing", birth_order_id: earlier.id })
          end
          raise Refused, "Your payment for #{name} has already gone through, so #{name} is being created " \
                         "and will appear with your residents. Nothing more was charged."
        end

        earlier.with_lock do
          next unless earlier.pending?

          @client.v1.subscriptions.cancel(remote.id) if remote && remote.status == "incomplete"
          earlier.update!(state: "abandoned", birth_attributes: {})
        end
      end
    end

    # The order's subscription, found through its metadata if opening it had
    # an uncertain answer (the id was never recorded).
    def remote_subscription(order)
      if order.stripe_subscription_id.present?
        return @client.v1.subscriptions.retrieve(order.stripe_subscription_id)
      end

      found = @client.v1.subscriptions.search({ query: "metadata['birth_order_id']:'#{order.id}'" }).data.first
      order.update!(stripe_subscription_id: found.id) if found
      found
    end

    # Step 1: the resident is created and the order marked born, in one local
    # transaction, before Stripe hears of it. A birth that fails rolls back
    # and is recorded as failed outside that transaction.
    def bear_if_paid!(order)
      failure = nil
      remote = nil
      order.with_lock do
        next unless order.pending? || order.failed?

        remote = remote_subscription(order)
        next unless remote && remote.status.in?(PAID)

        begin
          agent = Agents::HostedBirth.new(account: order.account, creator: order.creator,
            attributes: order.birth_attributes.symbolize_keys, open_beginning: order.open_beginning, paid: true).create!
          order.update!(state: "born", agent: agent, born_at: Time.current, birth_attributes: {}, last_error: nil)
        rescue ActiveRecord::RecordInvalid, Agents::HostedProvisioning::ConfigurationError => error
          failure = error
          raise ActiveRecord::Rollback
        end
      end
      fail!(order, remote, failure) if failure
    end

    # Step 2, after the birth has committed: Stripe names the resident, and
    # the subscription is brought in so the plan is in force. Repeatable.
    def link!(order)
      remote = @client.v1.subscriptions.retrieve(order.stripe_subscription_id)
      if remote.metadata["agent_id"].to_s != order.agent_id.to_s
        @client.v1.subscriptions.update(remote.id, {
          metadata: { agent_id: order.agent_id.to_s, birth_order_id: order.id.to_s },
          description: "#{order.tier_record.name} hosting for #{order.agent.name}"
        })
      end
      SubscriptionSync.new(remote.id, client: @client).call
    end

    def fail!(order, remote, error)
      order.reload.update!(state: "failed", last_error: error.message.first(500))
      Rails.error.report(error, handled: true,
        context: { subsystem: "billing", birth_order_id: order.id, stripe_subscription_id: remote&.id })
      raise error
    end

    def client_secret(subscription)
      subscription.latest_invoice&.confirmation_secret&.client_secret ||
        raise(Refused, "Stripe didn't open the first payment. Try again in a moment.")
    end

  end
end
