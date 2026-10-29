# Paying for a resident as the last step of creating it, in an account that
# pays per resident (Daniel, oewbQY 2026-10-25).
#
# One ResidentBirthOrder is the identity of one paid creation, from the first
# click to the born resident; every step below can be repeated safely, by the
# browser or by the webhook, in any order:
#
#   start!       records the draft as an order, then opens the plan's
#                subscription at Stripe (first invoice open). The Stripe call
#                carries an idempotency key per order and the card it used is
#                stored, so an uncertain answer (timeout, network) is resolved
#                by replaying the identical call: Stripe returns the
#                subscription it made, or makes it now. Either way it is the
#                order's one subscription. A search that finds nothing is never
#                taken as proof that nothing was made.
#   payment      resumes an order: the client secret to pay its first invoice
#                (resolving an uncertain create first), or, if it is already
#                paid or born, completes and links it, so a retry after payment
#                never pays twice and a lost confirmation is recovered.
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
    def start!(account:, creator:, attributes:, open_beginning:, tier:, rate: "standard")
      offer = tier&.offer(rate)
      refuse!(account, creator, offer)
      refuse_house_model_at_cost!(offer, attributes, account: account, creator: creator)
      payment_method = current_payment_method!(account)
      Agents::VmBirthPolicy.current.refuse!(kind: :birth)
      raise Refused, "Give the resident a name first." if attributes[:name].to_s.strip.empty?
      if attributes[:system_prompt].to_s.strip.empty? && !open_beginning
        raise Refused, "Write a soul seed, or choose an open beginning."
      end

      settle_earlier!(account, creator)
      # The price is pinned on the order: an uncertain create is replayed with
      # the same idempotency key, so its parameters must not move when the
      # catalogue is re-costed in between (#619).
      order = ResidentBirthOrder.create!(account: account, creator: creator, tier: tier.id, rate: offer.rate,
        stripe_price_id: offer.price_id, billing_code_redemption: account.grant_for(offer.rate),
        birth_attributes: attributes.to_h, open_beginning: open_beginning)
      order.update!(stripe_payment_method_id: payment_method.id)
      subscription = open_subscription!(order)
      [ order, client_secret(subscription), payment_method.id ]
    end

    # Returns { client_secret:, payment_method_id: } to pay the first invoice,
    # or { paid: true } when it is already paid (the order is completed).
    def payment(order)
      # Born already: the payment went through and only the answer (or the
      # link to Stripe) was lost. Finish linking; the browser then confirms.
      if order.born?
        complete!(order)
        return { paid: true }
      end
      raise Refused, "This resident is no longer waiting for payment." unless order.pending? || order.failed?

      remote = resolve_subscription!(order)
      if remote.status.in?(PAID)
        complete!(order)
        return { paid: true }
      end
      raise Refused, "This resident is no longer waiting for payment." unless order.pending?

      payment_method = current_payment_method!(order.account)
      subscription = @client.v1.subscriptions.update(remote.id,
        { default_payment_method: payment_method.id, expand: [ "latest_invoice.confirmation_secret" ] })
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
        order.abandon!
        true
      end
      complete!(order) unless abandoned
      order
    end

    private

    def refuse!(account, creator, offer)
      raise Refused, "This account doesn't pay per resident." unless account.billing_required?
      raise Refused, "Only the account's owner can pay for a new resident." unless account.owned_by?(creator)
      raise Refused, "Paying for residents isn't open on this house yet." unless Billing.configured?
      raise Refused, "That plan can't be bought yet." unless offer&.purchasable?
      raise Refused, "This account can't buy plans at that rate." unless account.eligible_for?(offer.rate)
    end

    # At cost includes no house-model allowance, so a resident on a
    # house-funded model would be born unable to think. Judged on the model
    # the birth would actually use (the draft's, or the default HostedBirth
    # would supply), refused before any money moves; the wizard says the same
    # before the button.
    def refuse_house_model_at_cost!(offer, attributes, account:, creator:)
      return unless offer.at_cost?

      model_id = attributes[:model_id].presence || Agents::HostedBirth.default_model_id(account: account, creator: creator)
      return unless HouseInference::Offering.find(model_id.to_s)

      raise Refused, "At cost includes no house model. Choose a model you connect a subscription or key for, " \
                     "or a plan with an allowance."
    end

    def current_payment_method!(account)
      PaymentMethod.new(account: account, client: @client).current ||
        raise(Refused, "Add a card to pay for the plan first.")
    end

    # Opens the order's subscription, or, replayed after an uncertain answer
    # with the same key and the same stored card, returns the one Stripe made
    # the first time. Stripe's answer is recorded before anything else can
    # happen to the order.
    #
    # The payload for a standard order is byte-for-byte what it was before
    # rates existed: an uncertain order opened by an older deploy is replayed
    # by a newer one under the same idempotency key, and Stripe refuses a key
    # whose parameters moved. Only an at-cost order carries its rate.
    def open_subscription!(order)
      offer = order.offer
      customer = BillingCustomer.find_by!(account: order.account)
      metadata = { birth_order: order.reference, account_id: order.account_id.to_s, tier: offer.tier.id }
      unless offer.standard?
        metadata[:rate] = offer.rate
        metadata[:redemption_id] = order.billing_code_redemption_id.to_s
      end
      subscription = @client.v1.subscriptions.create({
        customer: customer.stripe_customer_id,
        items: [ { price: order.stripe_price_id.presence || offer.price_id } ],
        default_payment_method: order.stripe_payment_method_id,
        payment_behavior: "default_incomplete",
        payment_settings: { save_default_payment_method: "on_subscription" },
        automatic_tax: { enabled: true },
        description: "#{offer.name} hosting for #{order.resident_name}",
        metadata: metadata,
        expand: [ "latest_invoice.confirmation_secret" ]
      }, { idempotency_key: "souls-house-birth-order-#{order.reference}" })
      order.update!(stripe_subscription_id: subscription.id, last_error: nil)
      subscription
    rescue Stripe::APIConnectionError, Stripe::APIError, Stripe::RateLimitError => error
      order.update!(last_error: "Opening the subscription: #{error.class.name.demodulize}")
      raise Uncertain.new(order)
    end

    # The order's subscription for certain: retrieved by its id, or, if
    # opening it had an uncertain answer, by replaying that call.
    def resolve_subscription!(order)
      if order.stripe_subscription_id.present?
        @client.v1.subscriptions.retrieve(order.stripe_subscription_id)
      else
        open_subscription!(order)
      end
    end

    # One open order per person and account. An earlier unpaid one is
    # replaced (its subscription cancelled). An earlier paid one is never
    # replaced: it is completed, and the new request is refused, so nobody
    # pays twice for one intention.
    def settle_earlier!(account, creator)
      ResidentBirthOrder.where(account: account, creator: creator, state: %w[pending failed]).find_each do |earlier|
        # Resolved for certain (replayed if it was uncertain): a search miss
        # is not proof that Stripe made nothing.
        remote = begin
          resolve_subscription!(earlier)
        rescue Uncertain
          raise Refused, "Stripe is still confirming your earlier request. Try again in a minute."
        end
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
          earlier.abandon!
        end
      end
    end

    # The order's subscription as Stripe knows it, found through its metadata
    # if the id was never recorded. Only for checks that may safely see
    # nothing yet: a recent subscription can be missing from search for a
    # minute. The sweeper uses it after expires_at, long past that.
    def remote_subscription(order)
      if order.stripe_subscription_id.present?
        return @client.v1.subscriptions.retrieve(order.stripe_subscription_id)
      end

      found = @client.v1.subscriptions.search({ query: "metadata['birth_order']:'#{order.reference}'" }).data.first
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
          order.mark_born!(agent: agent)
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
          metadata: { agent_id: order.agent_id.to_s, birth_order: order.reference },
          description: "#{order.offer.name} hosting for #{order.agent.name}"
        })
      end
      SubscriptionSync.new(remote.id, client: @client).call
    end

    def fail!(order, remote, error)
      order.reload.record_failure!(error.message)
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
