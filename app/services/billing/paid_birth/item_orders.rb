# A paid creation in an account that already has a live subscription: the new
# resident goes onto that bill as a bill change with a birth op
# (Billing::Reconcile), not a subscription of its own. Nothing is charged
# when the owner confirms; the part-period and the resident's month go on the
# account's next bill, on the card already paying it.
#
#   start_item!   the order is made and its change proposed: the bill judged
#                 fit to carry a resident on credit, the update pinned, the
#                 quote taken from Stripe's preview. Nothing is sent.
#   confirm_item! the quote is checked again (a moved quote is proposed
#                 afresh and shown again, nothing sent), then the change is
#                 sent. When Stripe carries its lines, Billing::BillSync bears
#                 the resident and makes its row in one transaction.
#
# A sent order that can't be born just now (the bill past due, the birth
# itself failing) needs attention: the order is marked failed with what is
# wrong, its draft kept, the house told, and every later confirm, webhook or
# sweep tries again. Nothing here takes the line off the bill again.
module Billing
  class PaidBirth
    module ItemOrders

      ITEM = "item".freeze
      WAITS = [ ActiveRecord::RecordInvalid, Agents::HostedProvisioning::ConfigurationError, NotReady ].freeze

      # The quote moved before it was confirmed; the order carries the new one.
      class QuoteChanged < StandardError

        attr_reader :order

        def initialize(order)
          @order = order
          super("The account's bill changed since this was shown. Nothing was added; look at the new amount.")
        end

      end

      def confirm_item!(order, digest:)
        raise Refused, "This resident isn't added to the account's bill." unless order.item?

        order.reload
        return order if order.born?
        raise Refused, "This resident is no longer waiting to be created." unless order.pending? || order.failed?
        return resume_item!(order) if order.sent?

        if order.expires_at <= Time.current
          drop_item!(order)
          raise Refused, "This quote has expired. Nothing was added; start again."
        end
        settle_item(order) { reconcile(order).confirm(order.bill_change, digest:) }
      rescue Reconcile::QuoteChanged
        order.update!(bill_change: propose_item(order))
        raise QuoteChanged.new(order)
      end

      def item_payment(order)
        return { accepted: true } if order.born?
        raise Refused, "This resident is no longer waiting to be created." unless order.pending? || order.failed?
        return { item_quote: order.bill_change.quote } unless order.sent?

        resume_item!(order)
        { accepted: true }
      end

      def complete_item!(order) = resume_item!(order)

      # Finishes a sent order: its change recovered, the resident born when
      # the change lands.
      def resume_item!(order)
        order.reload
        return order unless order.item? && (order.pending? || order.failed?) && order.sent?

        settle_item(order) { reconcile(order).recover(order.bill_change) }
      end

      # The sweeper's: an unsent order past its time is dropped; a sent one
      # is finished.
      def expire_item!(order)
        order.reload
        return resume_item!(order) if order.sent?

        drop_item!(order)
        order
      end

      private

      # One send or recovery of the order's change, and what each outcome
      # means for the order.
      def settle_item(order)
        yield
        order.reload
      rescue *WAITS => error
        needs_attention!(order, "#{order.resident_name} can't be created yet: #{error.message} " \
          "It stays on the order; the house has been told.")
        order.reload
      rescue Reconcile::Uncertain
        raise Uncertain.new(order)
      rescue Reconcile::Refused => error
        # Stripe refused the change outright: nothing is on the bill.
        drop_item!(order)
        raise Refused, error.message
      end

      # Not in a transaction: proposing takes the account's billing lock,
      # which refuses inside one (CheckoutLock). An order whose proposal
      # fails is removed, as the transaction's rollback did: nothing of it
      # reached Stripe.
      def start_item!(account:, creator:, attributes:, open_beginning:, offer:)
        order = ResidentBirthOrder.create!(kind: ITEM, account: account, creator: creator, tier: offer.tier.id,
          rate: offer.rate, stripe_price_id: offer.price_id, stripe_description: "#{offer.name} hosting for #{attributes[:name]}",
          billing_code_redemption: account.grant_for(offer), birth_attributes: attributes.to_h,
          open_beginning: open_beginning)
        begin
          order.update!(bill_change: propose_item(order))
        rescue StandardError
          order.destroy!
          raise
        end
        order
      end

      def propose_item(order)
        reconcile(order).propose([ { op: "birth", order: order.reference, price: order.offer.price_id } ], by: order.creator)
      rescue Reconcile::Refused => error
        raise Refused, error.message
      end

      def drop_item!(order)
        order.with_lock { order.abandon! if order.pending? }
        change = order.bill_change
        change.abandon!("The order was dropped.") if change&.proposed?
      end

      # An earlier item order of this person's: an unsent one is replaced; a
      # sent one is finished, and the new request refused.
      def settle_item_order!(earlier)
        return drop_item!(earlier) unless earlier.sent?

        name = earlier.resident_name
        begin
          resume_item!(earlier)
        rescue Uncertain, Refused => error
          Rails.error.report(error, handled: true, context: { subsystem: "billing", birth_order_id: earlier.id })
        end
        return if earlier.reload.abandoned?

        raise Refused, "#{name} is already on the account's bill and is being created; it will appear with your " \
                       "residents. Nothing more was added."
      end

      def reconcile(order) = Reconcile.new(account: order.account, client: @client)

    end
  end
end
