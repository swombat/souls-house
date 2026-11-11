# Brings one Stripe subscription into the house. Never trusts the event's copy:
# it re-fetches the subscription from Stripe under the account's advisory lock,
# validates it against the account and the plan catalogue, and applies it. An
# older fetch can't land after a newer one. A subscription for an account's
# plan (metadata kind=account_plan) is AccountSubscriptionSync's.
#
# A subscription may carry several residents, one item each (one payment per
# account, eoXAEj). Each item is one ResidentSubscription, identified by the
# item's id. An item is bound to a resident by, in order: the item id the
# house recorded; the item's own agent_id metadata; and, only on a legacy
# single-item subscription, the subscription's agent_id metadata.
#
# An item the house can't trust (a price outside the catalogue, a quantity
# other than one, a resident of another account, a binding that contradicts
# the house's record or another item, a resident already paid for elsewhere)
# is still present: it is never treated as removed and never grants anything.
# Its row, if it has one, may only follow the subscription down (past_due,
# ended), so it can't outlive the money. While the subscription stays live,
# what the row already granted stands for Billing::GRACE_PERIOD from when it
# was first found unreadable (a replay doesn't move that), then ends, here or
# in Billing::SweepJob. The valid items around it still sync; the problem is
# raised after they commit, so the event is reported.
#
# A recorded item missing from the complete item list was removed: its
# resident's plan ends.
module Billing
  class SubscriptionSync

    LOCK_NAMESPACE = 7_242_004 # per account, for pg_advisory_xact_lock(int, int)
    LIVE = %w[trialing active past_due].freeze
    DOWNGRADES = (%w[past_due] + ResidentSubscription::ENDED_STATUSES).freeze

    def self.lock!(account_id)
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{Integer(account_id)})")
    end

    def initialize(stripe_subscription_id, client: Billing.client, now: Time.current)
      @stripe_subscription_id = stripe_subscription_id
      @client = client
      @now = now
    end

    # Returns the row for agent:, or without one the subscription's sole row
    # (nil when it has none or several).
    def call(agent: nil)
      first = fetch
      return AccountSubscriptionSync.new(@stripe_subscription_id, client: @client, now: @now).call if account_plan?(first)
      return complete_birth_order(first) if unborn?(first)

      account = account_for(first)
      @problems = []
      rows = ApplicationRecord.transaction do
        self.class.lock!(account.id)
        remote = fetch
        account_for(remote) == account || raise(InvalidSubscription, "Subscription #{@stripe_subscription_id} changed account")
        items = all_items(remote)
        synced = sync_items!(remote, items, account)
        end_removed!(remote, items)
        point_account!(remote, account)
        synced
      end
      raise InvalidSubscription, @problems.join("; ") if @problems.any?

      agent ? rows.find { |row| row.agent_id == agent.id } : (rows.one? ? rows.first : nil)
    end

    private

    def fetch
      @client.v1.subscriptions.retrieve(@stripe_subscription_id)
    end

    def account_plan?(remote)
      remote.metadata && remote.metadata["kind"] == AccountSubscriptionSync::KIND
    end

    # A subscription bought as the last step of creating a resident names its
    # birth order until the resident exists. Its events complete the birth
    # (if it is paid), which then brings the subscription in itself. Returns
    # nil while the resident isn't born.
    def unborn?(remote)
      remote.metadata && remote.metadata["agent_id"].blank? && remote.metadata["birth_order"].present?
    end

    def complete_birth_order(remote)
      order = ResidentBirthOrder.find_by(reference: remote.metadata["birth_order"])
      if order.nil? || order.stripe_subscription_id.present? && order.stripe_subscription_id != remote.id
        raise InvalidSubscription, "Subscription #{@stripe_subscription_id} names no birth order here"
      end
      # Opening the subscription had no certain answer, so the order never
      # learned its id: this event is how it does.
      order.update!(stripe_subscription_id: remote.id) if order.stripe_subscription_id.blank?
      PaidBirth.new(client: @client).complete!(order)
      order.born? ? ResidentSubscription.find_by(stripe_subscription_id: remote.id) : nil
    end

    # The paying customer decides the account. A subscription naming an
    # account in its metadata must name that one.
    def account_for(remote)
      customer = BillingCustomer.find_by(stripe_customer_id: stripe_id(remote.customer))
      customer || raise(InvalidSubscription, "Subscription #{@stripe_subscription_id} belongs to another customer")
      named = remote.metadata && remote.metadata["account_id"].presence
      if named && named.to_s != customer.account_id.to_s
        raise InvalidSubscription, "Subscription #{@stripe_subscription_id} names another account"
      end
      customer.account
    end

    # Every item, not the first page: absence from this list ends a resident.
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
      ids = items.map(&:id)
      raise NotReady, "Stripe's item listing for #{remote.id} repeats an item" unless ids.uniq.size == ids.size

      items
    end

    def legacy?(remote, items)
      items.one? && remote.metadata && remote.metadata["agent_id"].present?
    end

    def sync_items!(remote, items, account)
      legacy = legacy?(remote, items)
      bindings = items.map { |item| [ item, *bind(remote, item, legacy) ] }
      claimed = bindings.group_by { |_item, agent_id, _recorded| agent_id }

      bindings.filter_map do |item, agent_id, recorded|
        problem = item_problem(remote, item, agent_id, recorded, account, claimed)
        if problem
          @problems << "#{item.id}: #{problem}"
          follow_down!(remote, recorded) if recorded
          next
        end

        offer = Offer.for_price(stripe_id(item.price))
        agent = Agent.find(agent_id)
        row = record!(remote, item, agent, offer, recorded)
        flag_ungranted!(remote, item, legacy, agent, offer)
        resolve_attempt!(remote, item, legacy, agent)
        ResidentEntitlement.for_agent!(agent).apply_subscription!(row, now: @now)
        row.reload
      end
    end

    # [agent id (a string, :conflict or nil), the house's row for this item or nil]
    def bind(remote, item, legacy)
      recorded = ResidentSubscription.find_by(stripe_subscription_item_id: item.id)
      recorded ||= ResidentSubscription.find_by(stripe_subscription_id: remote.id, stripe_subscription_item_id: nil) if legacy
      named = item_metadata(item)["agent_id"].presence || (legacy ? remote.metadata["agent_id"].to_s : nil)
      return [ :conflict, recorded ] if recorded && named && named != recorded.agent_id.to_s

      [ recorded ? recorded.agent_id.to_s : named, recorded ]
    end

    def item_problem(remote, item, agent_id, recorded, account, claimed)
      return "its metadata names a resident other than the one the house recorded" if agent_id == :conflict
      return "names no resident" if agent_id.blank?
      return "recorded on #{recorded.stripe_subscription_id}" if recorded && recorded.stripe_subscription_id != remote.id
      return "quantity #{item[:quantity].inspect}, not 1" unless item[:quantity] == 1
      return "another item names the same resident" if claimed.fetch(agent_id).size > 1
      return "price #{stripe_id(item.price).inspect} is outside the plan catalogue" unless Offer.for_price(stripe_id(item.price))

      agent = Agent.find_by(id: agent_id)
      return "names no resident here (#{agent_id})" unless agent
      return "names a resident of another account" unless agent.account_id == account.id

      # Only an item that could pay for the resident can collide with another.
      return nil unless remote.status.in?(ResidentSubscription::LIVE_STATUSES)

      elsewhere = ResidentSubscription.live.where(agent_id: agent.id).where.not(id: recorded&.id)
      return "the resident is already paid for by #{elsewhere.first.stripe_subscription_id}" if elsewhere.exists?

      nil
    end

    def record!(remote, item, agent, offer, row)
      row ||= ResidentSubscription.new(stripe_subscription_id: remote.id)
      row.assign_attributes(
        agent: agent,
        account: agent.account,
        stripe_subscription_item_id: item.id,
        tier: offer.tier.id,
        rate: offer.rate,
        stripe_price_id: stripe_id(item.price),
        stripe_status: remote.status,
        current_period_end: period_end(remote, item),
        # When Stripe ends the free trial (Billing::Trial): it charges then, or
        # cancels without a card. Kept after the trial for the record.
        trial_end: remote[:trial_end] ? Time.zone.at(remote[:trial_end]) : row.trial_end,
        cancel_at_period_end: remote.cancel_at_period_end ? true : false,
        untrusted_since: nil,
        last_synced_at: @now
      )
      row.save!
      row
    end

    # An untrusted item's row only ever follows the subscription down, and
    # while the subscription stays live it is held for at most grace.
    def follow_down!(remote, row)
      return if row.stripe_subscription_id != remote.id

      if remote.status.in?(DOWNGRADES)
        return if row.stripe_status == remote.status

        row.update!(stripe_status: remote.status, last_synced_at: @now)
        ResidentEntitlement.for_agent!(row.agent).apply_subscription!(row, now: @now)
      elsif row.live?
        row.update!(untrusted_since: @now) if row.untrusted_since.nil?
        ResidentEntitlement.for_agent!(row.agent).expire_untrusted!(row, now: @now)
      end
    end

    # Recorded items the subscription no longer has were removed.
    def end_removed!(remote, items)
      present = items.map(&:id)
      ResidentSubscription.where(stripe_subscription_id: remote.id).where.not(stripe_subscription_item_id: nil)
        .where.not(stripe_subscription_item_id: present).find_each do |row|
        next if row.ended?

        row.update!(stripe_status: "canceled", last_synced_at: @now)
        ResidentEntitlement.for_agent!(row.agent).apply_subscription!(row, now: @now)
      end
    end

    # The account's one subscription: the first live one seen, kept until it
    # ends. Nothing reads it yet.
    def point_account!(remote, account)
      return unless remote.status.in?(LIVE)

      customer = BillingCustomer.find_by!(account: account)
      current = customer.stripe_subscription_id
      return if current == remote.id
      return if current && ResidentSubscription.live.where(stripe_subscription_id: current).exists?

      customer.update!(stripe_subscription_id: remote.id)
    end

    # The Checkout that bought this item is settled once its item is in.
    def resolve_attempt!(remote, item, legacy, agent)
      key = item_metadata(item)["checkout_attempt"].presence || (legacy ? remote.metadata["checkout_attempt"].presence : nil)
      return unless key

      BillingCheckoutAttempt.unresolved.where(idempotency_key: key, agent_id: agent.id).update_all(resolved_at: @now, updated_at: @now)
    end

    # A recognised at-cost price on a correctly linked item is accepted (the
    # money is taken; refusing would strand it) and the missing grant is
    # reported, unless the purchase names the redemption that authorised it:
    # this account's, for this rate, withdrawn or not, since a grant withdrawn
    # after the purchase is not abuse. A name that is not such a redemption
    # counts for nothing.
    def flag_ungranted!(remote, item, legacy, agent, offer)
      return if offer.standard?

      named = item_metadata(item)["redemption_id"].presence || (legacy ? remote.metadata["redemption_id"].presence : nil)
      return if named && BillingCodeRedemption.where(id: named, account_id: agent.account_id, effect: offer.rate).exists?
      return if agent.account.eligible_for?(offer.rate)

      AuditLog.create!(account: agent.account, action: "billing_rate_without_grant", auditable: agent,
        data: { "stripe_subscription_id" => remote.id, "stripe_subscription_item_id" => item.id, "rate" => offer.rate })
      Rails.error.report(UngrantedRate.new("Subscription #{remote.id} is at #{offer.rate} with no grant on account #{agent.account_id}"),
        handled: true, context: { subsystem: "billing", stripe_subscription_id: remote.id })
    end

    def item_metadata(item)
      (item[:metadata] || {}).to_h.transform_keys(&:to_s)
    end

    # Newer Stripe API versions keep the period on the subscription item.
    def period_end(remote, item)
      seconds = item[:current_period_end] || remote[:current_period_end]
      seconds && Time.zone.at(seconds)
    end

    def stripe_id(value)
      value.respond_to?(:id) ? value.id : value
    end

  end
end
