# Brings one Stripe subscription into the house, as lines: price and quantity
# (docs/proposals/2026-11-14-one-bill.md). It never trusts an event's copy: it
# re-fetches the subscription under the account's lock.
#
# Stripe says what is being paid for and whether it is paid. The house says
# who the lines are for: each resident's row (ResidentSubscription) and the
# plan's (AccountSubscription) name the subscription and the price they were
# sold at. A line of two is the two rows at that price.
#
#   1. If the account's submitted change (BillChange) has landed, that is, the
#      subscription carries exactly the lines it wanted, the house's rows are
#      changed as the change says and it is applied. This is the only way a
#      resident or plan comes onto a bill or leaves it while the bill lives.
#   2. If Stripe's lines are then the house's, every row follows the
#      subscription: its status, period and ending. A resident's entitlement
#      follows its row as before (ResidentEntitlement#apply_subscription!),
#      so grace, ending and the return to free hosting are unchanged.
#   3. If they differ and no change explains it, nothing is granted, charged
#      or repaired. The rows still follow the subscription down (past due,
#      ended), so nothing outlives the money, and the difference is reported
#      for a person (Billing::BillDrift).
#
# A subscription that has ended ends every row on it, whatever its lines.
module Billing
  class BillSync

    PAID = ResidentSubscription::PAID_STATUSES
    LIVE = %w[trialing active past_due].freeze
    DOWN = (%w[past_due] + ResidentSubscription::ENDED_STATUSES).freeze

    # The lines the house holds on a subscription: { price id => quantity }.
    def self.house_lines(stripe_subscription_id)
      lines = ResidentSubscription.live.where(stripe_subscription_id:).group(:stripe_price_id).count
      plan = AccountSubscription.live.find_by(stripe_subscription_id:)
      lines[plan.stripe_price_id] = lines.fetch(plan.stripe_price_id, 0) + 1 if plan
      lines
    end

    # The lines Stripe holds: { price id => quantity }, every page of items.
    def self.remote_lines(remote, client:)
      Items.all(remote, client:).each_with_object(Hash.new(0)) do |item, lines|
        lines[Items.id(item.price)] += item[:quantity].to_i
      end
    end

    def initialize(stripe_subscription_id, client: Billing.client, now: Time.current)
      @stripe_subscription_id = stripe_subscription_id
      @client = client
      @now = now
    end

    # Returns the applied change, or nil.
    def call
      account = account_for(fetch)
      drift = applied = nil
      ApplicationRecord.transaction do
        SubscriptionSync.lock!(account.id)
        remote = fetch
        account_for(remote) == account || raise(InvalidSubscription, "Subscription #{remote.id} changed account")
        lines = self.class.remote_lines(remote, client: @client)
        applied = land!(remote, lines, account)
        house = self.class.house_lines(remote.id)
        drift = [ lines, house ] if remote.status.in?(LIVE) && lines != house
        follow!(remote, trusted: drift.nil?)
        point_account!(remote, account)
      end
      report(account, *drift) if drift
      applied
    end

    private

    def fetch = @client.v1.subscriptions.retrieve(@stripe_subscription_id)

    # The paying customer decides the account.
    def account_for(remote)
      customer = BillingCustomer.find_by(stripe_customer_id: Items.id(remote.customer))
      customer || raise(InvalidSubscription, "Subscription #{@stripe_subscription_id} belongs to another customer")
      customer.account
    end

    def land!(remote, lines, account)
      change = BillChange.submitted.find_by(account:, stripe_subscription_id: remote.id)
      return nil unless change && landed?(remote, lines, change)

      change.ops.each { |op| send(:"apply_#{op.fetch("op")}", remote, account, op) }
      change.apply!(now: @now)
      change
    end

    # A change to the lines has landed when a live subscription carries them
    # (one still waiting for its first payment is not live); one that ends or
    # keeps the whole bill is told by the ending itself.
    def landed?(remote, lines, change)
      return false unless lines == change.wanted
      return remote.cancel_at_period_end ? true : false if change.ends_bill?
      return !remote.cancel_at_period_end if change.keeps_bill?

      remote.status.in?(LIVE)
    end

    def apply_add(remote, account, op)
      offer = Offer.for_price(op.fetch("price")) || raise(InvalidSubscription, "No offer at #{op["price"].inspect}")
      agent = account.agents.find(op.fetch("agent_id"))
      ResidentSubscription.create!(agent:, account:, stripe_subscription_id: remote.id, tier: offer.tier.id,
        rate: offer.rate, stripe_price_id: op.fetch("price"), stripe_status: remote.status, last_synced_at: @now)
    end

    def apply_end(remote, _account, op)
      row = row_of(remote, op)
      row.update!(stripe_status: "canceled", last_synced_at: @now)
      ResidentEntitlement.for_agent!(row.agent).apply_subscription!(row, now: @now)
    end

    def apply_resize(remote, _account, op)
      offer = Offer.for_price(op.fetch("price")) || raise(InvalidSubscription, "No offer at #{op["price"].inspect}")
      row_of(remote, op).update!(tier: offer.tier.id, rate: offer.rate, stripe_price_id: op.fetch("price"))
    end

    def apply_plan(remote, account, op)
      current = AccountSubscription.live.find_by(stripe_subscription_id: remote.id)
      return current&.update!(stripe_status: "canceled", last_synced_at: @now) if op["price"].blank?

      plan = AccountPlan.for_price(op["price"]) || raise(InvalidSubscription, "No plan at #{op["price"].inspect}")
      (current || AccountSubscription.new(account:, stripe_subscription_id: remote.id))
        .update!(plan: plan.id, stripe_price_id: op["price"], stripe_status: remote.status, last_synced_at: @now)
    end

    def apply_end_bill(*) = nil
    def apply_keep_bill(*) = nil

    def row_of(remote, op)
      ResidentSubscription.live.find_by!(stripe_subscription_id: remote.id, agent_id: op.fetch("agent_id"))
    end

    # Rows follow the subscription: always down, and up only when the lines
    # are the house's.
    def follow!(remote, trusted:)
      return unless trusted || remote.status.in?(DOWN)

      state = { stripe_status: remote.status, current_period_end: period_end(remote),
                cancel_at_period_end: remote.cancel_at_period_end ? true : false, last_synced_at: @now }
      ResidentSubscription.live.where(stripe_subscription_id: remote.id).find_each do |row|
        row.update!(state.merge(trial_end: remote[:trial_end] ? Time.zone.at(remote[:trial_end]) : row.trial_end,
          untrusted_since: nil))
        ResidentEntitlement.for_agent!(row.agent).apply_subscription!(row, now: @now)
      end
      AccountSubscription.live.where(stripe_subscription_id: remote.id).find_each do |plan|
        plan.update!(state.merge(past_due_since: remote.status == "past_due" ? plan.past_due_since || @now : nil))
      end
    end

    # The account's one subscription: the first live one seen, kept until it
    # has nothing live on it.
    def point_account!(remote, account)
      return unless remote.status.in?(LIVE)

      customer = BillingCustomer.find_by!(account:)
      current = customer.stripe_subscription_id
      return if current == remote.id || (current && self.class.house_lines(current).any?)

      customer.update!(stripe_subscription_id: remote.id)
    end

    def report(account, stripe, house)
      Rails.error.report(BillDrift.new("Subscription #{@stripe_subscription_id} carries #{stripe.inspect}; " \
        "the house holds #{house.inspect}"), handled: true, context: { subsystem: "billing", account_id: account.id })
    end

    # Newer Stripe API versions keep the period on the subscription item.
    def period_end(remote)
      seconds = remote.items.data.first&.[](:current_period_end) || remote[:current_period_end]
      seconds && Time.zone.at(seconds)
    end

  end
end
