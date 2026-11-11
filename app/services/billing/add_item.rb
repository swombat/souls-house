# Adding a resident's plan to the account's live subscription, as one more
# item, instead of opening a second subscription (one payment per account,
# eoXAEj slice 2a). The part-period goes on the next invoice
# (create_prorations); nothing is charged on the day.
#
# Stripe allows a price once per subscription, so the new item carries its
# offer's catalogue price or, when another resident already holds it, an
# inline copy (Billing::ItemPrice), decided when the quote pins the update.
#
#   quote    under the account lock: brings the parent subscription in, checks
#            it can carry another resident on credit, pins the exact update
#            (payload, proration date, idempotency key) on a new attempt, and
#            previews what it will cost. Nothing is sent to Stripe but reads.
#   confirm! under the lock again: the quote the owner saw must still be what
#            Stripe would do (same parent, same items, same totals), otherwise
#            QuoteChanged and a fresh quote. Then submitted_at commits, and the
#            pinned update is sent under the attempt's key.
#
# An update sent with no certain answer is replayed, same key and payload,
# within REPLAY_WINDOW of being sent; after that the attempt is found by its
# key on the parent's items, and if no item carries it an operator settles it.
# It is never sent again under a new key. The webhook's SubscriptionSync
# resolves the attempt by the same key, so a lost answer needs no browser.
#
# A legacy parent (one resident, named in the subscription's metadata) is
# converted by the same update: its item gets the purchase's provenance
# (resident, rate, redemption, order), and the subscription-level resident
# metadata is cleared, so nothing can bind the wrong item by it afterwards.
module Billing
  class AddItem

    Refused = ItemQuote::Refused

    class QuoteChanged < StandardError; end

    KIND = "item".freeze
    REPLAY_WINDOW = Checkout::REPLAY_WINDOW
    UNCERTAIN = [ Stripe::APIConnectionError, Stripe::APIError, Stripe::RateLimitError ].freeze
    RESIDENT_KEYS = ItemQuote::RESIDENT_KEYS

    # Whether this account's next paid resident is an item on its live
    # subscription. Then Checkout and a new subscription are refused.
    def self.applies?(account)
      ResidentSubscription.live.where(account: account).exists?
    end

    def initialize(agent:, tier: nil, rate: "standard", client: Billing.client, now: Time.current)
      @agent, @client, @now = agent, client, now
      @offer = tier&.offer(rate)
    end

    # Returns the attempt, unsent, with its quote.
    def quote
      CheckoutLock.synchronize(@agent) do
        raise AlreadySubscribed, "#{@agent.name} already has a subscription; change it from the Billing tab" if paid_for?
        raise NotEligible, "This account has no live subscription to add to." unless self.class.applies?(@agent.account)

        grant = check_offer!
        settle_earlier!
        BillInFlight.refuse_add!(@agent.account)
        raise AlreadySubscribed, "#{@agent.name} already has a subscription; change it from the Billing tab" if paid_for?

        parent = items.parent!
        key = "souls-house-add-item-#{SecureRandom.uuid}"
        payload = items.payload(parent, metadata(key, grant))
        quote = items.preview(parent, payload)
        BillingCheckoutAttempt.create!(kind: KIND, agent: @agent, account: @agent.account, tier: @offer.tier.id,
          rate: @offer.rate, stripe_price_id: @offer.price_id, billing_code_redemption: grant,
          idempotency_key: key, create_params: payload, stripe_subscription_id: parent.id, quote: quote)
      end
    end

    # Sends the attempt's pinned update if the quote still holds. Returns
    # the resident's ResidentSubscription.
    def confirm!(attempt, digest:)
      CheckoutLock.synchronize(@agent) do
        attempt.reload
        unless attempt.kind == KIND && attempt.agent_id == @agent.id && attempt.resolved_at.nil?
          raise QuoteChanged, "That price is no longer on offer. Choose the plan again."
        end
        next recover!(attempt) if attempt.submitted_at?

        @offer = Tier.find!(attempt.tier).offer(attempt.rate)
        recheck!(attempt, digest)
        attempt.update!(submitted_at: Time.current)
        submit!(attempt)
      end
    end

    # An attempt sent with no certain answer: replayed, or found by its key.
    # The caller holds the account lock.
    def recover!(attempt)
      return submit!(attempt) if attempt.submitted_at > REPLAY_WINDOW.ago

      parent = @client.v1.subscriptions.retrieve(attempt.stripe_subscription_id)
      item = items.all_items(parent).find { |row| item_metadata(row)["checkout_attempt"] == attempt.idempotency_key }
      unless item
        raise NotReady, "Adding #{@agent.name} needs operator reconciliation. Contact #{Billing.contact_email}; " \
                        "nothing more will be charged."
      end
      land!(attempt, item)
    end

    def self.digest(quote) = ItemQuote.digest(quote)

    private

    def paid_for?
      ResidentSubscription.live.exists?(agent: @agent)
    end

    def check_offer!
      raise NotConfigured, "That plan has no Stripe price configured" unless @offer&.purchasable?

      grant = @agent.account.grant_for(@offer.rate)
      unless @offer.standard? || grant
        raise NotEligible, "This account can't buy plans at that rate. Redeem your billing code first."
      end
      if @offer.at_cost? && HouseInference::Offering.find(@agent.model_id.to_s)
        raise NotEligible, "At cost includes no house-model allowance. Choose a model on your own subscription or key in the resident's settings first."
      end
      grant
    end

    # Earlier ways of paying for this resident are closed first: an unsent
    # quote is dropped, a sent one is finished, a Checkout is expired (or, if
    # it may have been paid, refused).
    def settle_earlier!
      BillingCheckoutAttempt.unresolved.where(agent: @agent, kind: KIND).find_each do |earlier|
        if earlier.submitted_at?
          recover!(earlier)
        else
          earlier.update!(resolved_at: Time.current)
        end
      end
      Checkout.new(agent: @agent, tier: @offer.tier, rate: @offer.rate, success_url: nil, cancel_url: nil,
        client: @client).close_all!
    end

    def items = (@items ||= ItemQuote.new(account: @agent.account, offer: @offer, client: @client, now: @now))

    # What names the new item's purchase.
    def metadata(key, grant)
      metadata = { agent_id: @agent.id.to_s, account_id: @agent.account_id.to_s, tier: @offer.tier.id,
                   checkout_attempt: key }
      metadata.merge!(rate: @offer.rate, redemption_id: grant.id.to_s) unless @offer.standard?
      metadata
    end

    # The quote stands only if nothing it was made from has moved.
    def recheck!(attempt, digest)
      BillInFlight.refuse_add!(@agent.account)
      quote = attempt.quote.to_h
      stale = digest.to_s != self.class.digest(quote) || !@offer.purchasable? || @offer.price_id != attempt.stripe_price_id ||
        (!@offer.standard? && @agent.account.grant_for(@offer.rate)&.id != attempt.billing_code_redemption_id)
      stale ||= items.stale?(quote, parent_id: attempt.stripe_subscription_id, payload: attempt.create_params.deep_symbolize_keys)
      return unless stale

      attempt.update!(resolved_at: Time.current)
      raise QuoteChanged, "The price changed since it was shown. Here is the new one; nothing was charged."
    end

    def submit!(attempt)
      remote = @client.v1.subscriptions.update(attempt.stripe_subscription_id,
        attempt.create_params.deep_symbolize_keys, { idempotency_key: attempt.idempotency_key })
      item = items.all_items(remote).find { |row| item_metadata(row)["checkout_attempt"] == attempt.idempotency_key }
      raise NotReady, "Stripe's answer doesn't show #{@agent.name}'s plan yet. Try again in a minute." unless item

      land!(attempt, item)
    rescue *UNCERTAIN
      raise NotReady, "Stripe didn't answer in time. Nothing more will be charged; try again to finish adding #{@agent.name}."
    rescue Stripe::IdempotencyError
      raise NotReady, "Adding #{@agent.name} needs operator reconciliation. Contact #{Billing.contact_email}; " \
                      "nothing more will be charged."
    rescue Stripe::InvalidRequestError, Stripe::CardError => error
      # A definite refusal: Stripe applied nothing.
      attempt.update!(resolved_at: Time.current)
      raise Refused, "Stripe refused the change: #{error.message}"
    end

    def land!(attempt, item)
      attempt.update!(stripe_subscription_item_id: item.id) if attempt.stripe_subscription_item_id.blank?
      row = SubscriptionSync.new(attempt.stripe_subscription_id, client: @client).call(agent: @agent)
      attempt.update!(resolved_at: Time.current) if attempt.reload.resolved_at.nil? && row
      row || raise(NotReady, "#{@agent.name}'s plan is added; the house is still bringing it in.")
    end

    def item_metadata(item) = (item[:metadata] || {}).to_h.transform_keys(&:to_s)

    def stripe_id(value) = value.respond_to?(:id) ? value.id : value

  end
end
