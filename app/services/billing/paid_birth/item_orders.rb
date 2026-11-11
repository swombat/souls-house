# A paid creation in an account that already has a live subscription: the
# new resident is added to it as one more item (eoXAEj slice 2b), not given
# a subscription of its own. It is an accepted deferred-charge order: nothing
# is charged when the owner confirms; the part-period and the resident's
# month go on the account's next bill, on the card already paying it.
#
#   start_item!   under the account's resident-billing lock, after earlier
#                 orders are settled: the parent is judged fit to carry a
#                 resident on credit (Billing::ItemQuote), and the order is
#                 made with its kind, the pinned update (item metadata names
#                 the order, never a resident: none exists yet), its key and
#                 the quote. Nothing is sent.
#   confirm_item! under the lock: before submission the draft, the offer
#                 and the quote are checked again (a moved quote is re-pinned
#                 and shown again, nothing sent); then item_submitted_at
#                 commits and the pinned update is sent under the order's
#                 key. After submission nothing is re-quoted or re-keyed: an
#                 uncertain answer is replayed within the replay window, and
#                 after it the item is looked for; none means an operator.
#   receipt       before the order records an item, is born or is linked:
#                 a submitted item order; the pinned parent, belonging to
#                 the order's account by its customer; exactly one item
#                 naming the order; quantity 1; the actual price vouched for
#                 as the order's offer and rate (Billing::ItemPrice); no
#                 other resident on it. The parent's own status is never the
#                 evidence; it is checked separately, to decide whether the
#                 birth may go ahead now.
#   birth/link    HostedBirth and mark_born! in one local transaction, as
#                 for any order; then link_item! checks the receipt again and
#                 writes the resident on the item only (never on the
#                 subscription, never over another resident), and brings the
#                 subscription in.
#
# An accepted item whose parent can no longer carry it (past due, paused,
# ending), or whose birth fails, needs attention: the order is marked failed
# with what is wrong, its draft kept, the house told, and every later
# confirm, webhook or sweep tries again. Nothing here re-adds the item or
# cancels the account's subscription; taking an accepted item off again is a
# separate, explicit reconciliation.
module Billing
  class PaidBirth
    module ItemOrders

      ITEM = "item".freeze
      UNCERTAIN = [ Stripe::APIConnectionError, Stripe::APIError, Stripe::RateLimitError ].freeze

      class QuoteChanged < StandardError

        attr_reader :order

        def initialize(order)
          @order = order
          super("The price changed since it was shown. Here is the new one; nothing was added.")
        end

      end

      # Confirms the order's pinned add and creates the resident once the
      # item is verified. Returns the order.
      def confirm_item!(order, digest:)
        raise Refused, "This resident isn't added to the account's bill." unless order.item?

        CheckoutLock.synchronize_residents(order.account) do
          order.reload
          next complete!(order) if order.born?
          raise Refused, "This resident is no longer waiting to be created." unless order.pending? || order.failed?

          recheck_item!(order, digest) unless order.item_submitted_at?
          submit_item!(order)
          complete!(order)
        end
      end

      # The order's next step for the wizard: its quote while unsent,
      # accepted once sent (finishing what can be finished).
      def item_payment(order)
        if order.born?
          complete!(order)
          return { accepted: true }
        end
        raise Refused, "This resident is no longer waiting to be created." unless order.pending? || order.failed?
        return { item_quote: order.item_quote } unless order.item_submitted_at?

        CheckoutLock.synchronize_residents(order.account) do
          submit_item!(order.reload) if order.stripe_subscription_item_id.blank?
          complete!(order)
        end
        { accepted: true }
      end

      private

      def start_item!(account:, creator:, attributes:, open_beginning:, offer:)
        quoter = ItemQuote.new(account: account, offer: offer, client: @client)
        parent = quoter.parent!
        order = ResidentBirthOrder.create!(kind: ITEM, account: account, creator: creator, tier: offer.tier.id,
          rate: offer.rate, stripe_price_id: offer.price_id, stripe_description: "#{offer.name} hosting for #{attributes[:name]}",
          billing_code_redemption: account.grant_for(offer.rate), birth_attributes: attributes.to_h,
          open_beginning: open_beginning)
        pin_item!(order, quoter, parent)
        order
      end

      def pin_item!(order, quoter, parent)
        payload = quoter.payload(parent, item_metadata(order))
        order.update!(stripe_subscription_id: parent.id, item_create_params: payload,
          item_quote: quoter.preview(parent, payload))
      end

      # What names the new item's purchase: the order, never a resident.
      def item_metadata(order)
        metadata = { birth_order: order.reference, account_id: order.account_id.to_s, tier: order.tier }
        metadata.merge!(rate: order.rate, redemption_id: order.billing_code_redemption_id.to_s) unless order.offer.standard?
        metadata
      end

      def item_key(order) = "souls-house-birth-item-#{order.reference}"

      # Before anything is sent: the draft, the offer and the quote still
      # hold, or the order is re-pinned and the owner sees the new quote.
      def recheck_item!(order, digest)
        offer = order.offer
        refuse!(order.account, order.creator, offer)
        refuse_house_model_at_cost!(offer, order.birth_attributes.symbolize_keys, account: order.account, creator: order.creator)
        Agents::VmBirthPolicy.current.refuse!(kind: :birth)
        if !offer.standard? && order.account.grant_for(offer.rate)&.id != order.billing_code_redemption_id
          raise Refused, "This account's billing code changed. Start again."
        end

        quoter = ItemQuote.new(account: order.account, offer: offer, client: @client)
        stale = digest.to_s != ItemQuote.digest(order.item_quote) || offer.price_id != order.stripe_price_id ||
          quoter.stale?(order.item_quote, parent_id: order.stripe_subscription_id,
            payload: order.item_create_params.deep_symbolize_keys)
        if stale
          order.update!(stripe_price_id: offer.price_id)
          pin_item!(order, quoter, quoter.parent!)
          raise QuoteChanged.new(order)
        end
        order.update!(item_submitted_at: Time.current, last_error: nil)
      end

      # The pinned update, sent (or replayed) under the order's key, and the
      # item it made recorded on the order. Past the replay window the item
      # is only looked for. The caller holds the account lock.
      def submit_item!(order)
        remote = if order.item_submitted_at > AddItem::REPLAY_WINDOW.ago
          @client.v1.subscriptions.update(order.stripe_subscription_id, order.item_create_params.deep_symbolize_keys,
            { idempotency_key: item_key(order) })
        else
          @client.v1.subscriptions.retrieve(order.stripe_subscription_id)
        end
        item = order_item(order, remote)
        unless item
          raise NotReady, "Adding #{order.resident_name} needs operator reconciliation. Contact #{Billing.contact_email}; " \
                          "nothing more will be added."
        end
        order.update!(stripe_subscription_item_id: item.id, last_error: nil) if order.stripe_subscription_item_id.blank?
        item
      rescue *UNCERTAIN => error
        order.update!(last_error: "Adding to the account's subscription: #{error.class.name.demodulize}")
        raise Uncertain.new(order, "Stripe didn't answer in time. #{order.resident_name} is kept; try again. " \
                                   "Nothing more will be added.")
      rescue Stripe::IdempotencyError
        raise NotReady, "Adding #{order.resident_name} needs operator reconciliation. Contact #{Billing.contact_email}; " \
                        "nothing more will be added."
      rescue Stripe::InvalidRequestError, Stripe::CardError => error
        # A definite refusal: Stripe added nothing. The order can't be sent
        # again under its key, so it ends here; the wizard keeps the draft.
        order.with_lock { order.abandon! if order.pending? }
        raise Refused, "Stripe refused to add #{order.resident_name}: #{error.message} Nothing was added."
      end

      # The one item naming the order on remote, or nil.
      def order_item(order, remote)
        matches = item_quoter(order).all_items(remote).select { |item| item_meta(item)["birth_order"] == order.reference }
        raise InvalidSubscription, "Two items on #{remote.id} name birth order #{order.reference}" if matches.size > 1

        matches.first
      end

      # [parent, item, carries] for a verified accepted add, or nil while
      # there is no item yet. Anything that contradicts the order raises.
      def item_receipt(order)
        return nil unless order.item? && order.item_submitted_at? && order.stripe_subscription_id.present?

        parent = @client.v1.subscriptions.retrieve(order.stripe_subscription_id)
        customer = BillingCustomer.find_by(stripe_customer_id: stripe_id(parent.customer))
        unless customer && customer.account_id == order.account_id
          raise InvalidSubscription, "Subscription #{parent.id} isn't the account's for birth order #{order.reference}"
        end

        item = order_item(order, parent)
        return nil unless item

        problem = if order.stripe_subscription_item_id.present? && order.stripe_subscription_item_id != item.id
          "the order recorded #{order.stripe_subscription_item_id}"
        elsif item[:quantity] != 1
          "quantity #{item[:quantity].inspect}"
        elsif (offer = ItemPrice.new(client: @client).offer_for(item)).nil? || offer.tier.id != order.tier || offer.rate != order.rate
          "its price isn't the order's #{order.offer.name}"
        elsif (named = item_meta(item)["agent_id"].presence) && named != order.agent_id.to_s
          "it names resident #{named}"
        end
        raise InvalidSubscription, "Item #{item.id} for birth order #{order.reference}: #{problem}" if problem

        [ parent, item, item_quoter(order).carries?(parent) ]
      end

      # Step 1 for an item order, under the order's row lock: born only on a
      # verified accepted item whose parent can still carry it.
      def bear_item!(order)
        receipt = item_receipt(order)
        return :waiting unless receipt

        parent, item, carries = receipt
        order.update!(stripe_subscription_item_id: item.id) if order.stripe_subscription_item_id.blank?
        return [ :attention, "The account's subscription is #{parent_state(parent)}, so #{order.resident_name} " \
                             "can't be created yet. It stays on the order; the house has been told." ] unless carries

        agent = Agents::HostedBirth.new(account: order.account, creator: order.creator,
          attributes: order.birth_attributes.symbolize_keys, open_beginning: order.open_beginning, paid: true).create!
        order.mark_born!(agent: agent)
        :born
      end

      # Step 2: the exact item checked again, then the resident written on
      # it (only if the item names nobody yet), and the subscription brought
      # in.
      def link_item!(order)
        parent, item, = item_receipt(order)
        raise NotReady, "#{order.resident_name}'s place on the account's subscription isn't there yet." unless item

        if item_meta(item)["agent_id"].blank?
          @client.v1.subscriptions.update(parent.id, { items: [ { id: item.id, metadata: { agent_id: order.agent_id.to_s } } ] },
            { idempotency_key: "souls-house-birth-link-#{order.reference}" })
        end
        SubscriptionSync.new(parent.id, client: @client).call(agent: order.agent)
      end

      # An unsent item order is dropped (nothing exists at Stripe); a sent
      # one is finished, never dropped and never cancelled.
      def settle_item_order!(earlier)
        unless earlier.item_submitted_at?
          earlier.with_lock { earlier.abandon! if earlier.pending? }
          return
        end

        name = earlier.resident_name
        begin
          submit_item!(earlier) if earlier.stripe_subscription_item_id.blank?
          complete!(earlier)
        rescue StandardError => error
          Rails.error.report(error, handled: true, context: { subsystem: "billing", birth_order_id: earlier.id })
        end
        raise Refused, "#{name} is already on the account's bill and is being created; it will appear with your " \
                       "residents. Nothing more was added."
      end

      def parent_state(parent)
        return "set to end" if parent.cancel_at_period_end || parent[:cancel_at].present?
        return "paused" if parent[:pause_collection].present?
        return "waiting on an earlier change" if parent[:pending_update].present?

        parent.status.to_s.tr("_", " ")
      end

      def item_quoter(order) = ItemQuote.new(account: order.account, offer: order.offer, client: @client)

      def item_meta(item) = (item[:metadata] || {}).to_h.transform_keys(&:to_s)

      def stripe_id(value) = value.respond_to?(:id) ? value.id : value

    end
  end
end
