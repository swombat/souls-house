# Which resident subscription carries the account's house-model allowance
# ($10 a UTC month, Billing::Tier::ACCOUNT_ALLOWANCE_USD). Exactly one live
# standard-rate subscription in an account carries it: the first to be synced
# takes it, and when the carrier ends (or moves to at cost) the oldest
# remaining one takes it. At-cost residents never carry it: they bring their
# own model.
#
# Runs inside SubscriptionSync's transaction, under a per-account advisory
# lock taken after the per-resident one, so two webhooks for two residents of
# one account can't both grant it. A partial unique index is the backstop.
#
# Moving the carrier never gives the account a second $10 in a month: what
# any resident of the account has drawn on the paid allowance this month
# counts against the carrier's (ResidentEntitlement#allowance_spent).
module Billing
  class AllowanceCarrier

    LOCK_NAMESPACE = 7_242_002 # per account, after SubscriptionSync's per-resident lock

    def initialize(account, now: Time.current)
      @account = account
      @now = now
    end

    # Returns the carrier after settling (nil when the account has no live
    # standard-rate subscription).
    def settle!
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACE}, #{Integer(@account.id)})")
        scope = ResidentSubscription.where(account_id: @account.id)
        scope.where(includes_allowance: true).where.not(id: scope.can_carry_allowance.select(:id))
          .update_all(includes_allowance: false, updated_at: @now)

        carrier = scope.find_by(includes_allowance: true)
        unless carrier
          carrier = scope.can_carry_allowance.order(:created_at, :id).first
          if carrier
            carrier.update!(includes_allowance: true)
            note_ceiling!(carrier)
          end
        end
        carrier
      end
    end

    private

    # The new carrier's resident marks this month's ceiling at once, as an
    # activation would. A single statement, so it can't race that resident's
    # own sync into lowering it.
    def note_ceiling!(carrier)
      month = @now.utc.to_date.beginning_of_month
      amount = carrier.allowance_usd
      ResidentEntitlement.where(agent_id: carrier.agent_id).update_all([
        "allowance_limit_usd = CASE WHEN allowance_month = :month THEN GREATEST(COALESCE(allowance_limit_usd, 0), :amount) " \
        "ELSE :amount END, allowance_month = :month, updated_at = :now",
        { month: month, amount: amount, now: @now }
      ])
    end

  end
end
