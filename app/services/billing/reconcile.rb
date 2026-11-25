# Changes an account's bill (docs/proposals/2026-11-14-one-bill.md). Whatever
# changes (a resident added, ended or resized, the plan, the whole bill ending
# or kept), it is one act in three steps, each under the account's
# resident-billing lock:
#
#   propose   the subscription is brought in and must carry exactly what the
#             house holds; the lines after the change are worked out; the one
#             Stripe update that makes them so is pinned (payload, proration
#             date, idempotency key) on a BillChange, with Stripe's own
#             preview of what it costs. Only reads go to Stripe.
#   confirm   the quote the owner saw must still hold (same lines, same
#             totals), else QuoteChanged and nothing is sent. Then the change
#             is marked submitted and its pinned update sent. BillSync applies
#             it to the house once Stripe carries its lines.
#   recover   a send with no certain answer is replayed, same key and payload,
#             within REPLAY_WINDOW; after it the subscription is read: the
#             change landed, or Stripe never took it (abandoned), or neither
#             and an operator settles it. It is never sent again as new.
#
# A resident added to a paying account goes on the next invoice
# (create_prorations), as before: nothing is charged on the day, so the
# account's subscription must be fit to carry it on credit (active, a card,
# not paused or ending). Ending and keeping need only a live subscription.
#
# An account has one unresolved change at a time. A proposal that was never
# confirmed is dropped by the next one; a submitted one blocks until settled.
module Billing
  class Reconcile

    class Refused < StandardError; end
    class QuoteChanged < StandardError; end
    class Uncertain < StandardError; end

    REPLAY_WINDOW = 23.hours # Stripe may prune keys after 24h.
    UNCERTAIN = [ Stripe::APIConnectionError, Stripe::APIError, Stripe::RateLimitError ].freeze
    WAITING = "Another change to this account's bill is still being confirmed with Stripe. " \
              "Try again in a few minutes; nothing was changed.".freeze
    DRIFTED = "This account's bill needs a person to look at it before it can change.".freeze

    # Whether the account has a bill a new purchase goes onto.
    def self.applies?(account)
      ResidentSubscription.live.where(account:).exists? || AccountSubscription.live.where(account:).exists?
    end

    # The op that puts a resident already in the account onto its bill at
    # this size: at the included rate when it is the plan's own resident
    # (Billing::Included).
    def self.add_ops(account, agent, offer, client: Billing.client)
      Checkout.release_expired!(account, client:)
      [ { op: "add", agent_id: agent.id, price: Included.offer_for(account, offer).price_id } ]
    end

    def initialize(account:, client: Billing.client, now: Time.current)
      @account = account
      @client = client
      @now = now
    end

    def propose(ops, by: nil)
      ops = ops.map { |op| op.to_h.stringify_keys.compact }
      CheckoutLock.synchronize_residents(@account) do
        settle_earlier!
        # The subscription is brought in (parent!) before the ops are worked
        # out, so a change that landed while settling is seen: ending the
        # plan is decided on the bill as it now is (Mira, #1148).
        parent = parent!(ops)
        ops = with_demotion(with_promotion(with_successor(ending_plan(ops, parent))))
        base = BillSync.remote_lines(parent, client: @client)
        raise NotReady, "#{DRIFTED} Contact #{Billing.contact_email}." unless base == BillSync.house_lines(parent.id)

        lines = after(base, ops, parent)
        params = params_for(parent, base, lines, ops)
        BillChange.create!(account: @account, requested_by: by, stripe_subscription_id: parent.id,
          idempotency_key: "souls-house-bill-#{SecureRandom.uuid}", ops:, base:, lines:, params:,
          quote: quote(parent, params, lines))
      end
    end

    # Ending one resident's plan: off the bill now when the bill carries
    # anything else (another resident, or a plan line, which stays without
    # it), otherwise the whole bill ends at the period's end.
    def propose_end(agent, by: nil)
      row = ResidentSubscription.live.find_by(agent:, account: @account) ||
        raise(Refused, "#{agent.name} has no plan on this account's bill.")
      # Alone: nothing else on the bill, neither a resident nor a plan line.
      # A free trial's plan line is the trial's, not bought for itself: it
      # ends with the trial's resident, as before.
      alone = !ResidentSubscription.live.where(stripe_subscription_id: row.stripe_subscription_id)
        .where.not(id: row.id).exists? &&
        (row.stripe_status == "trialing" || !AccountSubscription.live.exists?(stripe_subscription_id: row.stripe_subscription_id))
      propose([ alone ? { op: "end_bill", agent_id: agent.id } : { op: "end", agent_id: agent.id } ], by:)
    end

    # Ending the account's plan (a plan stands alone on a bill: bought before
    # any resident, kept after the last one leaves). The bill ends at the
    # period's end when the plan is all it carries; otherwise the plan line
    # comes off now and the residents stay, the included one at its size.
    def propose_end_plan(by: nil)
      raise Refused, "This account has no plan on its bill." unless AccountSubscription.live.exists?(account: @account)

      propose([ { op: "end_plan" } ], by:)
    end

    def confirm(change, digest:)
      CheckoutLock.synchronize_residents(@account) do
        change.reload
        next change if change.applied?
        # Dropped by a later proposal, or refused: never sent, and never
        # reported as done.
        raise QuoteChanged, "This was replaced or dropped before it was confirmed. Nothing was sent; look at it again." if change.abandoned?

        unless change.submitted?
          unless digest == change.digest && holds?(change)
            change.abandon!("The bill moved before this was confirmed.", now: @now)
            raise QuoteChanged, "The bill changed since this was shown. Nothing was sent; look at it again."
          end
          change.submit!(now: @now)
        end
        deliver!(change)
      end
    end

    # Finishes a submitted change with no browser: the sweep, or the next
    # proposal on the account.
    def recover(change)
      CheckoutLock.synchronize_residents(@account) { change.reload.submitted? ? deliver!(change) : change }
    end

    private

    def settle_earlier!
      BillChange.unresolved.where(account: @account).find_each do |earlier|
        next earlier.abandon!("Replaced by a later proposal.", now: @now) if earlier.proposed?

        deliver!(earlier)
        raise NotReady, WAITING unless earlier.reload.resolved?
      rescue Uncertain
        raise NotReady, WAITING
      end
    end

    def deliver!(change)
      if @now < change.submitted_at + REPLAY_WINDOW
        @client.v1.subscriptions.update(change.stripe_subscription_id, change.params.deep_symbolize_keys,
          { idempotency_key: change.idempotency_key })
      end
      land!(change)
    rescue *UNCERTAIN
      raise Uncertain, "Stripe didn't answer in time. Nothing is lost; try again in a moment."
    rescue Stripe::InvalidRequestError, Stripe::CardError => error
      # Stripe refused it outright: nothing was applied.
      change.abandon!(error.message.to_s.first(250), now: @now)
      raise Refused, "Stripe refused the change: #{error.message}"
    end

    # BillSync decides what landed. Past the replay window with the
    # subscription still as it was, Stripe never took the change.
    def land!(change)
      BillSync.new(change.stripe_subscription_id, client: @client, now: @now).call
      change.reload
      return change if change.resolved? || @now < change.submitted_at + REPLAY_WINDOW

      remote = @client.v1.subscriptions.retrieve(change.stripe_subscription_id)
      untouched = BillSync.remote_lines(remote, client: @client) == change.base.transform_values(&:to_i) &&
        !change.ends_bill? && !change.keeps_bill?
      change.abandon!("Stripe never applied it.", now: @now) if untouched
      change
    end

    # Ending the account's plan, decided under the lock on the synced bill:
    # the whole bill at the period's end when the plan is all it carries,
    # otherwise the plan line off now.
    def ending_plan(ops, parent)
      return ops unless ops.any? { |op| op["op"] == "end_plan" }
      raise Refused, "Ending the plan is a change of its own." unless ops.one?
      raise Refused, "This account has no plan on its bill." unless AccountSubscription.live.exists?(stripe_subscription_id: parent.id)

      [ ResidentSubscription.live.exists?(stripe_subscription_id: parent.id) ? { "op" => "plan" } : { "op" => "end_bill" } ]
    end

    # When the included resident ends, the oldest standard-rate resident
    # left becomes the included one (a promote op). With none the plan
    # stays on the bill by itself: it was bought for itself as much as for
    # its resident (jGgWgj), and is ended from the plan, not with a
    # resident. Worked out once, here, and stored on the change, so a
    # replay judges the same ops; the same for the two below.
    def with_successor(ops)
      ends = ops.select { |op| op["op"] == "end" }
      return ops if ends.empty? || ops.any? { |op| op["op"].in?(%w[promote plan]) }

      ends.each do |op|
        row = row!(op)
        next unless row.rate == "included"

        successor = Included.successor(row.stripe_subscription_id, row.agent_id)
        next unless successor

        ops += [ { "op" => "promote", "agent_id" => successor.agent_id,
                   "price" => successor.offer.tier.offer("included").price_id } ]
      end
      ops
    end

    # A first plan line on a bill that already has residents at their size:
    # the oldest of them becomes the plan's included one in the same change,
    # so nobody pays a size's full price on top of the plan that includes it.
    # An account holding an at-cost code has no included resident.
    def with_promotion(ops)
      plan = ops.find { |op| op["op"] == "plan" && op["price"].present? }
      return ops if plan.nil? || @account.at_cost_holder? || ops.any? { |op| op["op"] == "promote" }

      id = subscription_of(plan)
      return ops if AccountSubscription.live.exists?(stripe_subscription_id: id)
      return ops if ResidentSubscription.live.exists?(stripe_subscription_id: id, rate: "included")

      first = ResidentSubscription.live.where(stripe_subscription_id: id, rate: "standard").order(:created_at, :id).first
      return ops unless first

      ops + [ { "op" => "promote", "agent_id" => first.agent_id, "price" => first.offer.tier.offer("included").price_id } ]
    end

    # The plan line leaving a bill its included resident stays on: that
    # resident goes back to its size (a demote op), since there is no plan
    # left to include it. A plan the house gives (Account#given_plan) still
    # includes it (Billing::Included), so then it stays.
    def with_demotion(ops)
      return ops unless ops.any? { |op| op["op"] == "plan" && op["price"].blank? }
      return ops if ops.any? { |op| op["op"] == "demote" } || @account.given_plan

      leaving = ops.select { |op| op["op"] == "end" }.map { |op| op["agent_id"] }
      ResidentSubscription.live.where(account: @account, rate: "included").where.not(agent_id: leaving)
        .order(:created_at, :id).each_with_object(ops.dup) do |row, all|
          all << { "op" => "demote", "agent_id" => row.agent_id, "price" => row.offer.tier.offer("standard").price_id }
        end
    end

    # The one subscription every op is about, brought in first.
    def parent!(ops)
      ids = ops.map { |op| subscription_of(op) }.uniq
      raise Refused, "One change is to one subscription." unless ids.one?

      BillSync.new(ids.first, client: @client, now: @now).call
      parent = @client.v1.subscriptions.retrieve(ids.first)
      raise Refused, "This account's subscription has ended." unless parent.status.in?(BillSync::LIVE)
      # The free trial's plan is the trial's: it ends with its resident
      # (propose_end), never changed or ended by itself.
      if parent.status == "trialing" && ops.any? { |op| op["op"].in?(%w[plan end_plan]) || (op["op"] == "end_bill" && !op["agent_id"]) }
        raise Refused, "The plan can't change while the account's free trial runs."
      end

      # Only what can grow the bill must be fit to carry it on credit; a plan
      # line leaving with its resident shrinks it.
      fit!(parent) if ops.any? { |op| op["op"].in?(%w[add birth resize]) || (op["op"] == "plan" && op["price"].present?) }
      parent
    end

    def subscription_of(op)
      if op["op"].in?(%w[end resize promote demote end_bill keep_bill]) && op["agent_id"]
        return row!(op).stripe_subscription_id
      end

      pointed = BillingCustomer.find_by(account: @account)&.stripe_subscription_id
      return pointed if pointed && BillSync.house_lines(pointed).any?

      ResidentSubscription.live.where(account: @account).order(:created_at, :id).first&.stripe_subscription_id ||
        AccountSubscription.live.where(account: @account).order(:id).first&.stripe_subscription_id ||
        raise(NotEligible, "This account has no live subscription to change.")
    end

    # Fit to carry more on credit: active, collecting, nothing pending, not
    # ending, with a card.
    def fit!(parent)
      if parent.status == "trialing"
        raise Refused, "The bill can't grow while the account's free trial runs. Add to it after the trial."
      end
      unless parent.status == "active"
        raise Refused, "The account's last payment hasn't gone through. Settle it in Manage billing first."
      end
      raise Refused, "The account's payments are paused. Resume them first." if parent[:pause_collection].present?
      if parent[:pending_update].present?
        raise Refused, "Stripe is still finishing an earlier change. Try again in a few minutes."
      end
      if parent.cancel_at_period_end || parent[:cancel_at].present?
        raise Refused, "The account's subscription is set to end. Keep it first."
      end
      return if parent[:default_payment_method].present? ||
        PaymentMethod.new(account: @account, client: @client).current.present?

      raise Refused, "Add a card first: Manage billing, then Add a card. Nothing is charged until the next bill."
    end

    # The lines after the ops, each op checked against the house.
    def after(base, ops, parent)
      lines = Hash.new(0).merge(base)
      ops.each do |op|
        case op["op"]
        when "add"
          lines[add!(op)] += 1
        when "birth"
          lines[birth!(op)] += 1
        when "end"
          lines[row!(op).stripe_price_id] -= 1
        when "resize"
          row = row!(op)
          offer = Offer.for_price(op["price"])
          unless offer&.purchasable? && offer.price_id == op["price"] && offer.rate == row.rate && offer.tier.id != row.tier
            raise Refused, "That isn't a size this resident can move to."
          end
          # The size it has is no grant for another: the account must hold
          # the rate for the size it moves to.
          unless @account.eligible_for?(offer)
            raise NotEligible, "This account can't buy #{offer.tier.name} at that rate."
          end
          lines[row.stripe_price_id] -= 1
          lines[op["price"]] += 1
        when "promote"
          row = row!(op)
          offer = Offer.for_price(op["price"])
          unless row.rate == "standard" && offer&.included? && offer.price_id == op["price"] && offer.tier.id == row.tier
            raise Refused, "That resident can't become the plan's included one."
          end
          # Only in place of the included resident leaving, or with the
          # bill's first plan line: never a second included resident.
          replaces = ops.any? { |other| other["op"] == "end" && row!(other).rate == "included" }
          first_plan = ops.any? { |other| other["op"] == "plan" && other["price"].present? } &&
            !AccountSubscription.live.exists?(stripe_subscription_id: parent.id) &&
            !ResidentSubscription.live.exists?(stripe_subscription_id: parent.id, rate: "included")
          raise Refused, "That resident can't become the plan's included one." unless replaces || first_plan
          lines[row.stripe_price_id] -= 1
          lines[op["price"]] += 1
        when "demote"
          row = row!(op)
          offer = Offer.for_price(op["price"])
          unless row.rate == "included" && offer&.rate == "standard" && offer.price_id == op["price"] && offer.tier.id == row.tier
            raise Refused, "That resident can't go back to its size."
          end
          unless ops.any? { |other| other["op"] == "plan" && other["price"].blank? }
            raise Refused, "The included resident goes back to its size only when the plan leaves the bill."
          end
          lines[row.stripe_price_id] -= 1
          lines[op["price"]] += 1
        when "plan"
          current = AccountSubscription.live.find_by(stripe_subscription_id: parent.id)
          plan = op["price"].presence && AccountPlan.for_price(op["price"])
          raise Refused, "That isn't a plan this house sells." if op["price"].present? && plan&.price_id != op["price"]
          if current&.stripe_price_id == op["price"]
            raise Refused, "The account is already on #{plan&.name || AccountPlan.default.name}."
          end

          if plan && (given = @account.given_plan) && given >= plan
            raise Refused, "The account already has the #{given.name} plan, with nothing to pay for it."
          end

          lines[current.stripe_price_id] -= 1 if current
          lines[op["price"]] += 1 if plan
          raise Refused, "This bill has no plan to take off." if !plan && !current
        end
      end
      lines = lines.select { |_price, quantity| quantity.positive? }
      if ops.any? { |op| op["op"] == "keep_bill" } && !ended_here?(parent)
        raise Refused, "This bill isn't ending because of something done here. Look at Manage billing."
      end
      ends = ops.find { |op| op["op"] == "end_bill" }
      if ends && !ends["agent_id"] && (ResidentSubscription.live.exists?(stripe_subscription_id: parent.id) ||
          !AccountSubscription.live.exists?(stripe_subscription_id: parent.id))
        # Ending the plan ends the whole bill only while the plan is all it
        # carries: checked again when the quote is confirmed.
        raise Refused, "This bill carries more than its plan now. Look at it again."
      end
      whole = ops.any? { |op| op["op"].in?(%w[end_bill keep_bill]) }
      raise Refused, "A change either ends or keeps the whole bill, or changes its lines." if whole && ops.size > 1
      raise Refused, "That changes nothing on the bill." if lines == base && !whole
      raise Refused, "The last line of a bill ends with the bill." if lines.empty?

      lines
    end

    # What a new resident's line is sold at: the offer's current price, to an
    # account that may buy at that rate, for a resident not already paid for.
    def add!(op)
      offer = Offer.for_price(op["price"])
      raise NotConfigured, "That plan has no Stripe price configured" unless offer&.purchasable? && offer.price_id == op["price"]

      agent = @account.agents.find(op.fetch("agent_id"))
      raise AlreadySubscribed, "#{agent.name} already has a plan." if ResidentSubscription.live.exists?(agent:)
      unless offer.catalogue? || @account.grant_for(offer)
        raise NotEligible, "This account can't buy plans at that rate. Redeem your billing code first."
      end
      included!(offer)
      if offer.at_cost? && HouseInference::Offering.find(agent.model_id.to_s)
        raise NotEligible, "At cost includes no house-model allowance. Choose a model on your own subscription " \
          "or key in the resident's settings first."
      end
      # Any hosted Checkout the resident could still pay is closed first, so
      # its plan can't be bought twice.
      Checkout.new(agent:, tier: offer.tier, rate: offer.rate, success_url: nil, cancel_url: nil, client: @client).close_all!
      op["price"]
    end

    # A resident about to be created onto the bill: this account's order,
    # still waiting, at its offer's current price.
    def birth!(op)
      order = ResidentBirthOrder.find_by(account: @account, reference: op["order"], kind: "item")
      raise Refused, "That resident is no longer waiting to be created." unless order&.pending? || order&.failed?
      unless order.offer.purchasable? && order.offer.price_id == op["price"]
        raise NotConfigured, "That plan has no Stripe price configured"
      end
      unless order.offer.catalogue? || @account.grant_for(order.offer)
        raise NotEligible, "This account can't buy plans at that rate. Redeem your billing code first."
      end
      included!(order.offer, except_order: order)
      op["price"]
    end

    # A catalogue resident is at the rate Billing::Included gives it: the
    # included one only when the account has none, standard otherwise.
    def included!(offer, except_order: nil)
      return unless offer.catalogue?
      return if Included.offer_for(@account, offer, except_order:) == offer

      raise Refused, offer.included? ? "This account already has its plan's included resident." :
        "This resident is the plan's included one; it is sold at the included price."
    end

    # Whether the subscription is ending because the house ended it: its last
    # applied change here ended the whole bill. An ending made elsewhere is
    # not the house's to undo.
    def ended_here?(parent)
      parent.cancel_at_period_end &&
        BillChange.where(account: @account, stripe_subscription_id: parent.id, state: "applied")
          .order(:resolved_at, :id).last&.ends_bill?
    end

    def row!(op)
      ResidentSubscription.live.find_by(account: @account, agent_id: op["agent_id"]) ||
        raise(Refused, "That resident has no plan on this account's bill.")
    end

    # The one update: a quantity for each line that changes, a deletion for
    # each that goes, a new item for each that arrives.
    def params_for(parent, base, lines, ops)
      return { cancel_at_period_end: true } if ops.any? { |op| op["op"] == "end_bill" }
      return { cancel_at_period_end: false } if ops.any? { |op| op["op"] == "keep_bill" }

      held = Items.all(parent, client: @client).group_by { |item| Items.id(item.price) }
      items = (base.keys | lines.keys).sort.filter_map do |price|
        next if base[price] == lines[price]
        next { price:, quantity: lines[price] } unless held[price]

        item = held[price].sole
        lines[price] ? { id: item.id, quantity: lines[price] } : { id: item.id, deleted: true }
      end
      { items:, proration_behavior: "create_prorations", proration_date: @now.to_i }
    end

    # What the owner confirms. Amounts are Stripe's own invoice totals (tax
    # and discounts in), never sums of lines: what the change puts on the
    # next bill, that bill's total, and a plain month afterwards.
    def quote(parent, params, lines)
      shown = { "parent" => parent.id, "lines" => lines, "ends" => params[:cancel_at_period_end],
                "next_at" => parent.items.data.first&.[](:current_period_end) }.compact
      customer = BillingCustomer.find_by!(account: @account).stripe_customer_id
      if params[:cancel_at_period_end]
        # The last bill: only what is already waiting for it.
        final = @client.v1.invoices.create_preview({ customer:, subscription: parent.id,
          subscription_details: { cancel_at_period_end: true } })
        return shown.merge("currency" => final.currency, "final_total" => final.total.to_i)
      end
      return shown unless params[:items]

      details = params.slice(:items, :proration_behavior, :proration_date)
      before = @client.v1.invoices.create_preview({ customer:, subscription: parent.id })
      after = @client.v1.invoices.create_preview({ customer:, subscription: parent.id, subscription_details: details })
      monthly = @client.v1.invoices.create_preview({ customer:, subscription: parent.id, preview_mode: "recurring",
        subscription_details: { items: params[:items], proration_behavior: "none" } })
      shown.merge("currency" => after.currency, "added_next" => after.total.to_i - before.total.to_i,
        "next_total" => after.total.to_i, "recurring_total" => monthly.total.to_i,
        "next_at" => after[:next_payment_attempt] || after[:period_end])
    end

    # Whether the quote still holds: the same subscription carrying the same
    # lines, still fit, every op still one the house would propose today (a
    # grant withdrawn or a price retired since refuses it), and Stripe's
    # totals unmoved. Only before sending: a submitted change is never
    # judged again.
    def holds?(change)
      parent = parent!(change.ops)
      base = change.base.transform_values(&:to_i)
      return false unless parent.id == change.stripe_subscription_id
      return false unless BillSync.remote_lines(parent, client: @client) == base
      return false unless after(base, change.ops, parent) == change.wanted

      quote(parent, change.params.deep_symbolize_keys, change.lines).except("next_at") == change.quote.except("next_at")
    rescue Refused, NotReady, NotEligible, NotConfigured, AlreadySubscribed, ActiveRecord::RecordNotFound
      false
    end

  end
end
