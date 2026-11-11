# Ending one resident's plan on the account's bill (eoXAEj slice 3, Mira
# emmNyb). Two operations, decided from every item Stripe has on the
# subscription (not only the ones the house has bound to residents):
#
#   delete      the subscription carries other items: this resident's item is
#               removed now (create_prorations at a pinned proration date),
#               the resident sleeps, and the unused part of the period comes
#               off the next bill as credit (never a refund to the card).
#   period_end  it is the subscription's only item: the subscription is set
#               to end at the period's end and won't renew. The resident runs
#               until then. Charges already waiting from earlier changes are
#               still billed on that date (shown from Stripe's preview).
#
#   quote    under the account lock: the parent brought in and checked, the
#            operation chosen, the update pinned (payload, proration date,
#            idempotency key) on a new attempt naming parent, item and
#            operation, and Stripe's preview of what it does. Only reads.
#   confirm! under the lock again: the parent, its items and Stripe's preview
#            must be what was shown, otherwise QuoteChanged and a fresh
#            quote. Then submitted_at commits and the pinned update is sent.
#
# An update sent with no certain answer is replayed under its key within
# REPLAY_WINDOW; after that the outcome is read from the subscription (the
# item gone, or the subscription ending under this attempt's key), and if
# neither shows, an operator settles it. Nothing ends locally on the strength
# of a send: SubscriptionSync decides what ended. The sweep finishes a sent
# attempt with no browser (resume!).
#
# keep! undoes a period_end only when the subscription is ending under a key
# this resident's own end attempt set, never an ending made elsewhere.
module Billing
  class EndItem

    class Refused < StandardError; end
    class QuoteChanged < StandardError; end

    KIND = "end".freeze
    DELETE = "delete".freeze
    PERIOD_END = "period_end".freeze
    REPLAY_WINDOW = Checkout::REPLAY_WINDOW
    UNCERTAIN = AddItem::UNCERTAIN
    # Unsent quotes older than this are dropped by the sweep.
    QUOTE_TTL = 1.hour

    def self.digest(quote) = ItemQuote.digest(quote)

    def initialize(agent:, client: Billing.client, now: Time.current)
      @agent, @client, @now = agent, client, now
    end

    # Returns the attempt, unsent, with its quote.
    def quote
      CheckoutLock.synchronize(@agent) do
        settle_earlier!
        row = live_row!
        parent = parent!(row.stripe_subscription_id)
        item = item!(parent, row)
        operation = items.all_items(parent).one? ? PERIOD_END : DELETE
        key = "souls-house-end-item-#{SecureRandom.uuid}"
        payload = payload(operation, item, key)
        BillingCheckoutAttempt.create!(kind: KIND, agent: @agent, account: @agent.account, tier: row.tier, rate: row.rate,
          stripe_price_id: row.stripe_price_id.presence || stripe_id(item.price), idempotency_key: key,
          create_params: payload, stripe_subscription_id: parent.id, stripe_subscription_item_id: item.id,
          quote: preview(parent, item, operation, payload))
      end
    end

    # Sends the attempt's pinned update if the quote still holds. Returns
    # the attempt, resolved.
    def confirm!(attempt, digest:)
      CheckoutLock.synchronize(@agent) do
        attempt.reload
        unless attempt.kind == KIND && attempt.agent_id == @agent.id && attempt.resolved_at.nil?
          raise QuoteChanged, "That quote is no longer open. Choose End plan again."
        end
        next recover!(attempt) if attempt.submitted_at?

        recheck!(attempt, digest)
        attempt.update!(submitted_at: Time.current)
        submit!(attempt)
      end
    end

    # The sweep: a sent attempt finished with no browser. Unsent ones past
    # QUOTE_TTL are dropped.
    def resume!(attempt)
      CheckoutLock.synchronize(@agent) do
        attempt.reload
        next attempt unless attempt.kind == KIND && attempt.resolved_at.nil?
        next recover!(attempt) if attempt.submitted_at?

        attempt.update!(resolved_at: Time.current) if attempt.created_at < @now - QUOTE_TTL
        attempt
      end
    end

    # Undoes this resident's own period_end, before the period ends.
    def keep!
      CheckoutLock.synchronize(@agent) do
        row = live_row!
        parent = @client.v1.subscriptions.retrieve(row.stripe_subscription_id)
        ending = BillingCheckoutAttempt.find_by(kind: KIND, agent: @agent, idempotency_key: metadata(parent)["ending_attempt"].to_s)
        # Stripe sets cancel_at to the period's end alongside
        # cancel_at_period_end; any other date was set elsewhere.
        unless parent.cancel_at_period_end && [ nil, period_end(parent) ].include?(parent[:cancel_at]) && ending&.resolved_at? &&
               ending.create_params["cancel_at_period_end"] == true && ending.stripe_subscription_id == parent.id
          raise Refused, "#{@agent.name}'s plan wasn't set to end from here, so it can't be kept from here. " \
                         "Write to #{Billing.contact_email}."
        end
        @client.v1.subscriptions.update(parent.id, { cancel_at_period_end: false, metadata: { ending_attempt: "", ending_agent: "" } },
          { idempotency_key: "souls-house-keep-#{ending.idempotency_key}" })
        SubscriptionSync.new(parent.id, client: @client).call(agent: @agent)
      rescue *UNCERTAIN
        raise NotReady, "Stripe didn't answer in time. Try Keep again; it is safe to repeat."
      end
    end

    private

    def items = (@items ||= ItemQuote.new(account: @agent.account, offer: nil, client: @client, now: @now))

    def live_row!
      ResidentSubscription.live.find_by(agent: @agent) ||
        raise(NotEligible, "#{@agent.name} has no plan to end.")
    end

    # Earlier end attempts: an unsent one is dropped, a sent one finished.
    def settle_earlier!
      BillingCheckoutAttempt.unresolved.where(agent: @agent, kind: KIND).find_each do |earlier|
        earlier.submitted_at? ? recover!(earlier) : earlier.update!(resolved_at: Time.current)
      end
    end

    # The subscription, brought in first, in a state where ending one plan
    # means what the quote says.
    def parent!(id)
      SubscriptionSync.new(id, client: @client).call
      parent = @client.v1.subscriptions.retrieve(id)
      unless parent.status.in?(%w[active trialing])
        raise Refused, "The account's last payment hasn't gone through. Settle it in Manage billing first."
      end
      raise Refused, "The account's payments are paused. Resume them first." if parent[:pause_collection].present?
      raise Refused, "Stripe is still finishing an earlier change. Try again in a few minutes." if parent[:pending_update].present?
      if parent.cancel_at_period_end || parent[:cancel_at].present?
        raise Refused, "This bill is already set to end at #{date(period_end(parent))}."
      end
      parent
    end

    # The resident's own item, as the house has it bound. An item the house
    # can't place is never guessed at.
    def item!(parent, row)
      all = items.all_items(parent)
      item = row.stripe_subscription_item_id && all.find { |candidate| candidate.id == row.stripe_subscription_item_id }
      item ||= all.first if row.stripe_subscription_item_id.nil? && all.one?
      item || raise(NotReady, "#{@agent.name}'s plan needs operator attention before it can end. Contact #{Billing.contact_email}.")
    end

    def payload(operation, item, key)
      if operation == DELETE
        { items: [ { id: item.id, deleted: true } ], proration_behavior: "create_prorations", proration_date: @now.to_i }
      else
        { cancel_at_period_end: true, metadata: { ending_attempt: key, ending_agent: @agent.id.to_s } }
      end
    end

    # What the owner confirms, from Stripe's own invoice previews:
    #   delete      next_change (negative: the credit), next_total and
    #               recurring_total after the change
    #   period_end  final_total: what is still billed when the period ends
    #               (charges already waiting; 0 when none)
    def preview(parent, item, operation, payload)
      customer = BillingCustomer.find_by!(account: @agent.account).stripe_customer_id
      base = { "operation" => operation, "customer" => customer, "parent" => parent.id, "item" => item.id,
               "parent_items" => items.snapshot(parent), "ends_at" => period_end(parent) }
      if operation == DELETE
        details = payload.slice(:items, :proration_behavior, :proration_date)
        before = @client.v1.invoices.create_preview({ customer: customer, subscription: parent.id })
        after = @client.v1.invoices.create_preview({ customer: customer, subscription: parent.id, subscription_details: details })
        monthly = @client.v1.invoices.create_preview({ customer: customer, subscription: parent.id, preview_mode: "recurring",
          subscription_details: { items: payload[:items], proration_behavior: "none" } })
        base.merge("currency" => after.currency, "next_change" => after.total.to_i - before.total.to_i,
          "next_total" => after.total.to_i, "recurring_total" => monthly.total.to_i,
          "next_at" => after[:next_payment_attempt] || after[:period_end])
      else
        final = @client.v1.invoices.create_preview({ customer: customer, subscription: parent.id,
          subscription_details: { cancel_at_period_end: true } })
        base.merge("currency" => final.currency, "final_total" => final.total.to_i,
          "next_at" => final[:next_payment_attempt] || final[:period_end])
      end
    end

    # The quote stands only if nothing it was made from has moved: the
    # parent, every item on it, the operation, and Stripe's preview.
    def recheck!(attempt, digest)
      quote = attempt.quote.to_h
      stale = digest.to_s != self.class.digest(quote)
      unless stale
        row = live_row!
        parent = parent!(attempt.stripe_subscription_id)
        item = item!(parent, row)
        operation = items.all_items(parent).one? ? PERIOD_END : DELETE
        fresh = preview(parent, item, operation, attempt.create_params.deep_symbolize_keys)
        stale = row.stripe_subscription_id != attempt.stripe_subscription_id || item.id != attempt.stripe_subscription_item_id ||
          operation != quote["operation"] || fresh.except("next_at") != quote.except("next_at")
      end
      return unless stale

      attempt.update!(resolved_at: Time.current)
      raise QuoteChanged, "The account's bill changed since this was shown. Here it is again; nothing was changed."
    rescue NotEligible, NotReady, Refused
      attempt.update!(resolved_at: Time.current)
      raise
    end

    def submit!(attempt)
      remote = @client.v1.subscriptions.update(attempt.stripe_subscription_id,
        attempt.create_params.deep_symbolize_keys, { idempotency_key: attempt.idempotency_key })
      done?(attempt, remote) || raise(NotReady, "Stripe's answer doesn't show the change yet. Try again in a minute.")
      land!(attempt)
    rescue *UNCERTAIN
      raise NotReady, "Stripe didn't answer in time. Nothing was charged; try again to finish ending #{@agent.name}'s plan."
    rescue Stripe::IdempotencyError
      raise NotReady, "Ending #{@agent.name}'s plan needs operator reconciliation. Contact #{Billing.contact_email}."
    rescue Stripe::InvalidRequestError => error
      # A definite refusal: Stripe applied nothing.
      attempt.update!(resolved_at: Time.current)
      raise Refused, "Stripe refused the change: #{error.message}"
    end

    # A sent attempt: replayed within the window, read from the
    # subscription after it. The caller holds the account lock.
    def recover!(attempt)
      return submit!(attempt) if attempt.submitted_at > REPLAY_WINDOW.ago

      remote = @client.v1.subscriptions.retrieve(attempt.stripe_subscription_id)
      unless done?(attempt, remote)
        raise NotReady, "Ending #{@agent.name}'s plan needs operator reconciliation. Contact #{Billing.contact_email}."
      end
      land!(attempt)
    end

    # Whether the subscription shows this attempt's change.
    def done?(attempt, remote)
      if attempt.create_params["cancel_at_period_end"]
        remote.cancel_at_period_end == true && metadata(remote)["ending_attempt"] == attempt.idempotency_key
      else
        remote.status == "canceled" || items.all_items(remote).none? { |item| item.id == attempt.stripe_subscription_item_id }
      end
    end

    def land!(attempt)
      SubscriptionSync.new(attempt.stripe_subscription_id, client: @client).call
      attempt.update!(resolved_at: Time.current)
      attempt
    end

    def metadata(remote) = (remote.metadata || {}).to_h.transform_keys(&:to_s)

    def period_end(parent)
      items.all_items(parent).filter_map { |item| item[:current_period_end] }.min || parent[:current_period_end]
    end

    def date(timestamp) = timestamp ? I18n.l(Time.zone.at(timestamp).to_date, format: :long) : "the period's end"

    def stripe_id(value) = value.respond_to?(:id) ? value.id : value

  end
end
