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
# A free-trial order (Billing::Trial) is the same order with trial: true. It
# needs no card: instead of opening the subscription itself, start_trial!
# opens a Stripe Checkout (the order's pinned payload, its own idempotency
# key) that makes a trialing subscription, card optional. Its subscription is
# found through the Checkout session; from there payment, complete!, the
# webhook and the sweeper treat it as any other order, trialing being paid.
#
# In an account that already has a live subscription, the order is an item
# order instead (Billing::PaidBirth::ItemOrders): the resident is added to
# that subscription on credit, born once the accepted item is verified.
#
# Nothing is born before money has cleared, or, for an item order, before the
# account's subscription has accepted the item. A paid order is never replaced by
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

    include ItemOrders

    PAID = ResidentSubscription::PAID_STATUSES

    def initialize(client: Billing.client)
      @client = client
    end

    # Returns [order, client_secret, payment_method_id]; for an item order
    # (the account already has a live subscription) [order, nil, nil], the
    # order carrying the quote to confirm.
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

      # The kind is decided once, under the account's resident-billing lock
      # and after earlier orders are settled, and never inferred again.
      CheckoutLock.synchronize_residents(account) do
        settle_earlier!(account, creator)
        if AddItem.applies?(account)
          next [ start_item!(account: account, creator: creator, attributes: attributes, open_beginning: open_beginning,
            offer: offer), nil, nil ]
        end

        # The price is pinned on the order: an uncertain create is replayed with
        # the same idempotency key, so its parameters must not move when the
        # catalogue is re-costed in between (#619).
        order = ResidentBirthOrder.create!(account: account, creator: creator, tier: tier.id, rate: offer.rate,
          stripe_price_id: offer.price_id, stripe_description: "#{offer.name} hosting for #{attributes[:name]}",
          billing_code_redemption: account.grant_for(offer.rate),
          birth_attributes: attributes.to_h, open_beginning: open_beginning)
        order.update!(stripe_payment_method_id: payment_method.id)
        subscription = open_subscription!(order)
        [ order, client_secret(subscription), payment_method.id ]
      end
    end

    # The free trial: a small resident, standard rate, no card. Records the
    # draft as a trial order under the account's one claim (Billing::Trial)
    # and opens its Stripe Checkout. success_url may be a callable given the
    # order (Stripe returns the browser to the order). Returns
    # [order, checkout_url].
    def start_trial!(account:, creator:, attributes:, open_beginning:, success_url:, cancel_url:)
      offer = Trial.offer
      refuse!(account, creator, offer)
      Agents::VmBirthPolicy.current.refuse!(kind: :birth)
      raise Refused, "Give the resident a name first." if attributes[:name].to_s.strip.empty?
      if attributes[:system_prompt].to_s.strip.empty? && !open_beginning
        raise Refused, "Write a soul seed, or choose an open beginning."
      end
      raise Refused, "The free trial isn't offered here." unless Trial.offered?(account)
      # A trial that was spent is refused before an earlier order is touched.
      # One still waiting in another tab is this person's to replace.
      unless Trial.unspent?(account) || ResidentBirthOrder.pending.exists?(account: account, creator: creator, trial: true)
        raise Refused, Trial::SPENT
      end

      settle_earlier!(account, creator)
      customer = BillingCustomer.for!(account, client: @client)
      order = nil
      Trial.claim!(account) do
        order = ResidentBirthOrder.create!(account: account, creator: creator, tier: offer.tier.id, rate: offer.rate,
          stripe_price_id: offer.price_id, stripe_description: "#{offer.name} hosting for #{attributes[:name]}",
          birth_attributes: attributes.to_h, open_beginning: open_beginning, trial: true)
        success_url = success_url.call(order) if success_url.respond_to?(:call)
        order.update!(checkout_create_params: trial_checkout_params(order, customer, success_url, cancel_url))
      end
      session = resolve_checkout!(order)
      raise Refused, "Stripe didn't open the free trial. Try again in a moment." unless session.status == "open"

      [ order, session.url ]
    end

    # Returns { client_secret:, payment_method_id: } to pay the first invoice,
    # or { paid: true } when it is already paid (the order is completed). A
    # trial order has no invoice to pay: { checkout_url: } while its Checkout
    # is open.
    def payment(order)
      return trial_payment(order) if order.trial?
      return item_payment(order) if order.item?

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
      return complete_item!(order) if order.item?

      bear_if_paid!(order)
      link!(order.reload) if order.born?
      order
    end

    # The sweeper's: an order still unpaid at expires_at is abandoned. One
    # paid at the last moment is born instead.
    def abandon_expired!(order)
      return expire_item!(order) if order.item?

      abandoned = order.with_lock do
        next false unless order.pending?

        remote = remote_subscription(order)
        next false if remote && remote.status.in?(PAID)
        next false if order.trial? && !close_checkout!(order)

        @client.v1.subscriptions.cancel(remote.id) if remote && remote.status == "incomplete"
        order.abandon!
        Trial.release!(order)
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
        description: order.stripe_description.presence || legacy_description(order),
        metadata: metadata,
        expand: [ "latest_invoice.confirmation_secret" ]
      }, { idempotency_key: "souls-house-birth-order-#{order.reference}" })
      order.update!(stripe_subscription_id: subscription.id, last_error: nil)
      subscription
    rescue Stripe::APIConnectionError, Stripe::APIError, Stripe::RateLimitError => error
      order.update!(last_error: "Opening the subscription: #{error.class.name.demodulize}")
      raise Uncertain.new(order)
    end

    # Orders opened before the description was pinned (2026-11-10) used the
    # sizes' old names; a replay must send exactly that.
    LEGACY_NAMES = { "conversation" => "Conversation", "life" => "Life", "work" => "Work" }.freeze

    def legacy_description(order)
      name = LEGACY_NAMES.fetch(order.tier)
      name = "#{name} at cost" unless order.offer.standard?
      "#{name} hosting for #{order.resident_name}"
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
        next settle_item_order!(earlier) if earlier.item?

        # Resolved for certain (replayed if it was uncertain): a search miss
        # is not proof that Stripe made nothing.
        remote = begin
          earlier.trial? ? trial_subscription!(earlier) : resolve_subscription!(earlier)
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
          if earlier.trial? && !close_checkout!(earlier)
            raise Refused, "Stripe is still confirming your earlier request. Try again in a minute."
          end

          @client.v1.subscriptions.cancel(remote.id) if remote && remote.status == "incomplete"
          earlier.abandon!
          Trial.release!(earlier)
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
      if order.trial? && order.stripe_checkout_session_id.present?
        return subscription_of(order, @client.v1.checkout.sessions.retrieve(order.stripe_checkout_session_id))
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
      attention = nil
      order.with_lock do
        next unless order.pending? || order.failed?

        if order.item?
          begin
            _outcome, attention = bear_item!(order)
          rescue ActiveRecord::RecordInvalid, Agents::HostedProvisioning::ConfigurationError => error
            failure = error
            raise ActiveRecord::Rollback
          end
          next
        end

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
      needs_attention!(order, attention) if attention
    end

    # An accepted item order that can't be born just now: kept, with its
    # draft, marked failed with what is wrong, and the house told. Every
    # later confirm, webhook or sweep tries again.
    def needs_attention!(order, message)
      order.reload
      order.record_failure!(message) unless order.failed? && order.last_error == message
      Rails.error.report(NotReady.new(message), handled: true,
        context: { subsystem: "billing", birth_order_id: order.id, stripe_subscription_id: order.stripe_subscription_id })
    end

    # Step 2, after the birth has committed: Stripe names the resident, and
    # the subscription is brought in so the plan is in force. Repeatable.
    def link!(order)
      remote = @client.v1.subscriptions.retrieve(order.stripe_subscription_id)
      # Once the subscription is the account's (Billing::AddItem converted
      # it), its metadata names no resident: the item carries the order's
      # provenance, and an old retry must not write a resident back on top.
      if remote.metadata["kind"] != "account" && remote.metadata["agent_id"].to_s != order.agent_id.to_s
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

    # A trial order's Checkout: the session Stripe made for it, or, if
    # creating it had no certain answer, the same create replayed from the
    # pinned payload under the same key, which returns the session Stripe
    # made the first time. Read live afterwards: a replay can return the
    # cached open response of a session that has since completed.
    def resolve_checkout!(order)
      if order.stripe_checkout_session_id.blank?
        session = @client.v1.checkout.sessions.create(order.checkout_create_params.deep_symbolize_keys,
          { idempotency_key: "souls-house-birth-trial-#{order.reference}" })
        order.update!(stripe_checkout_session_id: session.id, last_error: nil)
      end
      @client.v1.checkout.sessions.retrieve(order.stripe_checkout_session_id)
    rescue Stripe::APIConnectionError, Stripe::APIError, Stripe::RateLimitError => error
      order.update!(last_error: "Opening the free trial: #{error.class.name.demodulize}")
      raise Uncertain.new(order)
    end

    # The trial order's subscription once its Checkout completed (nil before),
    # recording its id on the order.
    def trial_subscription!(order)
      return @client.v1.subscriptions.retrieve(order.stripe_subscription_id) if order.stripe_subscription_id.present?

      subscription_of(order, resolve_checkout!(order))
    end

    def subscription_of(order, session)
      id = session.subscription.respond_to?(:id) ? session.subscription.id : session.subscription
      return nil unless session.status == "complete" && id.present?

      order.update!(stripe_subscription_id: id) if order.stripe_subscription_id.blank?
      @client.v1.subscriptions.retrieve(id)
    end

    def trial_payment(order)
      if order.born?
        complete!(order)
        return { paid: true }
      end
      raise Refused, "This resident is no longer waiting for its free trial." unless order.pending? || order.failed?

      remote = trial_subscription!(order)
      if remote&.status&.in?(PAID) || order.failed?
        complete!(order)
        return { paid: true }
      end
      session = @client.v1.checkout.sessions.retrieve(order.stripe_checkout_session_id)
      raise Refused, "This free trial's checkout has closed. Start again." unless session.status == "open"

      { checkout_url: session.url }
    end

    # Makes sure a trial order's Checkout can no longer make a subscription:
    # true once its session is expired (or was never created, the replay
    # window having passed). False if it completed after all: the order is
    # then paid and must be born, not abandoned.
    def close_checkout!(order)
      return true if order.stripe_checkout_session_id.blank? && order.created_at < Checkout::REPLAY_WINDOW.ago

      session = resolve_checkout!(order)
      if session.status == "open"
        begin
          session = @client.v1.checkout.sessions.expire(session.id)
        rescue Stripe::InvalidRequestError
          session = @client.v1.checkout.sessions.retrieve(session.id)
        end
      end
      session.status == "expired"
    rescue Uncertain
      false
    end

    # The trial's Checkout, pinned on the order before Stripe hears of it. A
    # paid order's subscription payload and key are untouched by this.
    def trial_checkout_params(order, customer, success_url, cancel_url)
      metadata = { birth_order: order.reference, account_id: order.account_id.to_s, tier: order.tier, trial: "1" }
      {
        mode: "subscription", customer: customer.stripe_customer_id, client_reference_id: "birth-order-#{order.reference}",
        line_items: [ { price: order.stripe_price_id, quantity: 1 } ],
        payment_method_collection: "if_required",
        subscription_data: {
          trial_period_days: Trial::DAYS,
          trial_settings: { end_behavior: { missing_payment_method: "cancel" } },
          metadata: metadata, description: order.stripe_description
        },
        metadata: metadata, automatic_tax: { enabled: true }, tax_id_collection: { enabled: true },
        billing_address_collection: "required", customer_update: { address: "auto", name: "auto" },
        # Stripe closes it itself when the order would be abandoned.
        expires_at: order.expires_at.to_i,
        success_url: success_url, cancel_url: cancel_url
      }
    end

    def client_secret(subscription)
      subscription.latest_invoice&.confirmation_secret&.client_secret ||
        raise(Refused, "Stripe didn't open the first payment. Try again in a moment.")
    end

  end
end
