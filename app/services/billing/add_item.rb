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

    class Refused < StandardError

      attr_reader :reason

      def initialize(message, reason: nil)
        @reason = reason
        super(message)
      end

    end

    class QuoteChanged < StandardError; end

    KIND = "item".freeze
    REPLAY_WINDOW = Checkout::REPLAY_WINDOW
    UNCERTAIN = [ Stripe::APIConnectionError, Stripe::APIError, Stripe::RateLimitError ].freeze
    # Subscription-level keys that named one resident before the account's
    # subscription carried several. "" unsets a key at Stripe.
    RESIDENT_KEYS = %w[agent_id birth_order checkout_attempt tier rate redemption_id trial].freeze

    # Whether this account's next paid resident is an item on its live
    # subscription. Then Checkout and a new subscription are refused.
    def self.applies?(account)
      ResidentSubscription.live.where(account: account).exists?
    end

    def initialize(agent:, tier: nil, rate: "standard", client: Billing.client, now: Time.current)
      @agent, @client, @now = agent, client, now
      @offer = tier&.offer(rate)
      @prices = ItemPrice.new(client: client)
    end

    # Returns the attempt, unsent, with its quote.
    def quote
      CheckoutLock.synchronize(@agent) do
        raise AlreadySubscribed, "#{@agent.name} already has a subscription; change it from the Billing tab" if paid_for?
        raise NotEligible, "This account has no live subscription to add to." unless self.class.applies?(@agent.account)

        grant = check_offer!
        settle_earlier!
        raise AlreadySubscribed, "#{@agent.name} already has a subscription; change it from the Billing tab" if paid_for?

        parent = eligible_parent!
        key = "souls-house-add-item-#{SecureRandom.uuid}"
        payload = payload(parent, key, grant)
        quote = preview(parent, payload)
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
      item = all_items(parent).find { |row| item_metadata(row)["checkout_attempt"] == attempt.idempotency_key }
      unless item
        raise NotReady, "Adding #{@agent.name} needs operator reconciliation. Contact #{Billing.contact_email}; " \
                        "nothing more will be charged."
      end
      land!(attempt, item)
    end

    def self.digest(quote)
      Digest::SHA256.hexdigest(JSON.generate(quote.to_h.sort.to_h))
    end

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

    # The account's subscription, brought in first (its items' ids recorded,
    # the account pointed at it), and fit to carry another resident on
    # credit: active, collecting, no change pending, not ending, with a card.
    def eligible_parent!
      id = parent_id
      SubscriptionSync.new(id, client: @client).call
      parent = @client.v1.subscriptions.retrieve(id)
      case parent.status
      when "active"
      when "trialing"
        raise Refused.new("A resident can't be added while the account's free trial runs. " \
                          "It ends on #{trial_end(parent)}; add the resident after that.", reason: :trialing)
      else
        raise Refused.new("The account's last payment hasn't gone through. Settle it in Manage billing first.",
          reason: :unsettled)
      end
      if parent[:pause_collection].present?
        raise Refused.new("The account's payments are paused. Resume them first.", reason: :paused)
      end
      if parent[:pending_update].present?
        raise Refused.new("Stripe is still finishing an earlier change. Try again in a few minutes.", reason: :pending)
      end
      if parent.cancel_at_period_end || parent[:cancel_at].present?
        raise Refused.new("The account's subscription is set to end. Keep it in Manage billing first.",
          reason: :ending)
      end
      unless card?(parent)
        raise Refused.new("Add a card first: Manage billing, then Add a card. Nothing is charged until the next bill.",
          reason: :no_card)
      end
      if legacy?(parent) && all_items(parent).size != 1
        raise NotReady, "The account's subscription needs operator attention first. Contact #{Billing.contact_email}."
      end
      parent
    end

    def parent_id
      account = @agent.account
      pointed = BillingCustomer.find_by(account: account)&.stripe_subscription_id
      live = ResidentSubscription.live.where(account: account)
      return pointed if pointed && live.exists?(stripe_subscription_id: pointed)

      live.order(:created_at, :id).first.stripe_subscription_id
    end

    def card?(parent)
      parent[:default_payment_method].present? || PaymentMethod.new(account: @agent.account, client: @client).current.present?
    end

    def legacy?(parent)
      metadata = (parent.metadata || {}).to_h.transform_keys(&:to_s)
      metadata["kind"] != "account" && RESIDENT_KEYS.any? { |key| metadata[key].present? }
    end

    # The one update: the new item, and for a legacy parent its conversion.
    def payload(parent, key, grant)
      metadata = { agent_id: @agent.id.to_s, account_id: @agent.account_id.to_s, tier: @offer.tier.id,
                   checkout_attempt: key }
      metadata.merge!(rate: @offer.rate, redemption_id: grant.id.to_s) unless @offer.standard?
      items = []
      items << provenance(parent) if legacy?(parent)
      price = @prices.item_params(@offer, items: all_items(parent))
      items << price.merge(quantity: 1, metadata: metadata.merge(price[:metadata].symbolize_keys))
      payload = { items: items, proration_behavior: "create_prorations", proration_date: @now.to_i }
      if legacy?(parent)
        payload[:metadata] = RESIDENT_KEYS.index_with { "" }.merge("kind" => "account",
          "account_id" => @agent.account_id.to_s)
      end
      payload
    end

    # The legacy item takes over what named its resident and its purchase.
    def provenance(parent)
      item = all_items(parent).first
      row = ResidentSubscription.find_by!(stripe_subscription_item_id: item.id)
      from = (parent.metadata || {}).to_h.transform_keys(&:to_s).slice(*RESIDENT_KEYS).compact_blank
      { id: item.id, metadata: from.merge("agent_id" => row.agent_id.to_s, "account_id" => @agent.account_id.to_s) }
    end

    # What the owner is asked to confirm, and what confirm! checks again. All
    # amounts are Stripe's own invoice totals (tax and discounts in), never
    # sums of lines:
    #   added_next      what adding the resident adds to the next bill (that
    #                   bill with the change, less that bill without it)
    #   next_total      the whole next bill with the change, including any
    #                   one-off charges already waiting for it
    #   recurring_total a month's bill for every item after the change, with
    #                   no part-period or one-off charges (Stripe's recurring
    #                   estimate, which refuses prorations, so made without)
    def preview(parent, payload)
      customer = BillingCustomer.find_by!(account: @agent.account).stripe_customer_id
      items = payload[:items].map { |item| item.except(:metadata) }
      before = @client.v1.invoices.create_preview({ customer: customer, subscription: parent.id })
      after = @client.v1.invoices.create_preview({ customer: customer, subscription: parent.id,
        subscription_details: { items: items, proration_behavior: "create_prorations", proration_date: payload[:proration_date] } })
      monthly = @client.v1.invoices.create_preview({ customer: customer, subscription: parent.id, preview_mode: "recurring",
        subscription_details: { items: items, proration_behavior: "none" } })
      {
        "currency" => after.currency, "added_next" => after.total.to_i - before.total.to_i, "next_total" => after.total.to_i,
        "recurring_total" => monthly.total.to_i, "next_at" => after[:next_payment_attempt] || after[:period_end],
        "price" => @offer.price_id, "parent" => parent.id, "parent_items" => snapshot(parent)
      }
    end

    def snapshot(parent)
      all_items(parent).map { |item| "#{item.id}:#{stripe_id(item.price)}:#{item[:quantity]}" }.sort
    end

    # The quote stands only if nothing it was made from has moved.
    def recheck!(attempt, digest)
      quote = attempt.quote.to_h
      stale = digest.to_s != self.class.digest(quote) || !@offer.purchasable? || @offer.price_id != attempt.stripe_price_id ||
        (!@offer.standard? && @agent.account.grant_for(@offer.rate)&.id != attempt.billing_code_redemption_id)
      unless stale
        parent = eligible_parent!
        stale = parent.id != attempt.stripe_subscription_id || snapshot(parent) != quote["parent_items"] ||
          preview(parent, attempt.create_params.deep_symbolize_keys).except("next_at") != quote.except("next_at")
      end
      return unless stale

      attempt.update!(resolved_at: Time.current)
      raise QuoteChanged, "The price changed since it was shown. Here is the new one; nothing was charged."
    end

    def submit!(attempt)
      remote = @client.v1.subscriptions.update(attempt.stripe_subscription_id,
        attempt.create_params.deep_symbolize_keys, { idempotency_key: attempt.idempotency_key })
      item = all_items(remote).find { |row| item_metadata(row)["checkout_attempt"] == attempt.idempotency_key }
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

    def all_items(remote)
      items = remote.items.data.to_a
      return items unless remote.items.respond_to?(:has_more) && remote.items.has_more

      cursor = items.last&.id
      loop do
        page = @client.v1.subscription_items.list({ subscription: remote.id, limit: 100, starting_after: cursor })
        items.concat(page.data.to_a)
        break unless page.has_more

        next_cursor = page.data.last&.id
        raise NotReady, "Stripe's item listing for #{remote.id} is incomplete" if next_cursor.blank? || next_cursor == cursor

        cursor = next_cursor
      end
      items
    end

    def item_metadata(item) = (item[:metadata] || {}).to_h.transform_keys(&:to_s)

    def trial_end(parent)
      parent[:trial_end] ? I18n.l(Time.zone.at(parent[:trial_end]).to_date, format: :long) : "soon"
    end

    def stripe_id(value) = value.respond_to?(:id) ? value.id : value

  end
end
