# One more resident on the account's live subscription: the subscription
# judged fit to carry it on credit, the update that adds it pinned, and what
# that update will cost, from Stripe's own invoice totals. Shared by
# Billing::AddItem (an existing resident choosing a plan) and
# Billing::PaidBirth (a resident created onto the account's bill).
#
# The new item carries its offer's catalogue price, or an inline copy when a
# sibling holds it (Billing::ItemPrice). A legacy parent (one resident, named
# in the subscription's metadata) is converted by the same update: its item
# takes over the purchase's provenance and the subscription-level resident
# keys are cleared.
module Billing
  class ItemQuote

    class Refused < StandardError

      attr_reader :reason

      def initialize(message, reason: nil)
        @reason = reason
        super(message)
      end

    end

    # Subscription-level keys that named one resident before the account's
    # subscription carried several. "" unsets a key at Stripe.
    RESIDENT_KEYS = %w[agent_id birth_order checkout_attempt tier rate redemption_id trial].freeze

    def self.digest(quote)
      Digest::SHA256.hexdigest(JSON.generate(quote.to_h.sort.to_h))
    end

    def initialize(account:, offer:, client: Billing.client, now: Time.current)
      @account, @offer, @client, @now = account, offer, client, now
      @prices = ItemPrice.new(client: client)
    end

    # The account's subscription, brought in first (its items' ids recorded,
    # the account pointed at it), and fit to carry another resident on
    # credit: active, collecting, no change pending, not ending, with a card.
    def parent!(id = parent_id)
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

    # Whether the parent can still carry a resident on credit, without
    # raising: what a birth on an accepted item checks again.
    def carries?(parent)
      parent.status == "active" && parent[:pause_collection].blank? && parent[:pending_update].blank? &&
        !parent.cancel_at_period_end && parent[:cancel_at].blank?
    end

    def parent_id
      pointed = BillingCustomer.find_by(account: @account)&.stripe_subscription_id
      live = ResidentSubscription.live.where(account: @account)
      return pointed if pointed && live.exists?(stripe_subscription_id: pointed)

      live.order(:created_at, :id).first&.stripe_subscription_id ||
        raise(NotEligible, "This account has no live subscription to add to.")
    end

    # The one update: the new item (with metadata, which names its
    # purchase), and for a legacy parent its conversion.
    def payload(parent, metadata)
      items = []
      items << provenance(parent) if legacy?(parent)
      price = @prices.item_params(@offer, items: all_items(parent))
      items << price.merge(quantity: 1, metadata: metadata.merge(price[:metadata].symbolize_keys))
      payload = { items: items, proration_behavior: "create_prorations", proration_date: @now.to_i }
      if legacy?(parent)
        payload[:metadata] = RESIDENT_KEYS.index_with { "" }.merge("kind" => "account", "account_id" => @account.id.to_s)
      end
      payload
    end

    # What the owner is asked to confirm, and what is checked again before
    # sending. All amounts are Stripe's own invoice totals (tax and discounts
    # in), never sums of lines:
    #   added_next      what the add puts on the next bill (that bill with the
    #                   change, less that bill without it)
    #   next_total      the whole next bill with the change, including any
    #                   one-off charges already waiting for it
    #   recurring_total a month's bill for every item after the change, with
    #                   no part-period or one-off charges (Stripe's recurring
    #                   estimate, which refuses prorations, so made without)
    def preview(parent, payload)
      customer = BillingCustomer.find_by!(account: @account).stripe_customer_id
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

    # Whether a quote no longer holds: the parent it was made against, its
    # items, or what Stripe would charge have moved.
    def stale?(quote, parent_id:, payload:)
      parent = parent!
      parent.id != parent_id || snapshot(parent) != quote["parent_items"] ||
        preview(parent, payload).except("next_at") != quote.except("next_at")
    end

    def snapshot(parent)
      all_items(parent).map { |item| "#{item.id}:#{stripe_id(item.price)}:#{item[:quantity]}" }.sort
    end

    # Every item, past Stripe's embedded first page.
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

    def legacy?(parent)
      metadata = (parent.metadata || {}).to_h.transform_keys(&:to_s)
      metadata["kind"] != "account" && RESIDENT_KEYS.any? { |key| metadata[key].present? }
    end

    private

    def card?(parent)
      parent[:default_payment_method].present? || PaymentMethod.new(account: @account, client: @client).current.present?
    end

    # The legacy item takes over what named its resident and its purchase.
    def provenance(parent)
      item = all_items(parent).first
      row = ResidentSubscription.find_by!(stripe_subscription_item_id: item.id)
      from = (parent.metadata || {}).to_h.transform_keys(&:to_s).slice(*RESIDENT_KEYS).compact_blank
      { id: item.id, metadata: from.merge("agent_id" => row.agent_id.to_s, "account_id" => @account.id.to_s) }
    end

    def trial_end(parent)
      parent[:trial_end] ? I18n.l(Time.zone.at(parent[:trial_end]).to_date, format: :long) : "soon"
    end

    def stripe_id(value) = value.respond_to?(:id) ? value.id : value

  end
end
