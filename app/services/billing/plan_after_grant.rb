module Billing
  # When a plan code that gave the account its plan is withdrawn, the account
  # pays for its own plan (the one it chose, else Companions) on the bill it
  # already has: the bill takes on that plan's line, and the resident the
  # plan includes keeps its included price ($0 for a Small, the difference
  # for a bigger one). This is A's model with the grant gone
  # (plan_includes_resident_test): you pay for the plan, and it includes one
  # Small. Site Admin's withdraw step says so before it is pressed.
  #
  # Left as it is: an account still given any plan (another code, or the
  # house's grant), an at-cost holder (at cost has no included resident and
  # no plan to pay), an account with no bill or already paying for a plan,
  # and a plan with no Stripe price. Stripe can refuse the change for now (a
  # bill in its trial, past due, or ending); SweepJob retries those, for
  # accounts whose plan code was withdrawn, until it lands or no longer
  # applies.
  module PlanAfterGrant

    module_function

    def needed?(account)
      return false if account.given_plan || account.at_cost_holder?
      return false unless Reconcile.applies?(account)
      return false if AccountSubscription.live.where(account:).exists?
      return false unless ResidentSubscription.live.where(account:, rate: "included").exists?

      account.plan_to_pay_for&.purchasable? || false
    end

    # Returns the BillChange (applied, or submitted and still being
    # confirmed), or nil when there was nothing to put on.
    def restore!(account, by:, client: nil)
      return nil unless needed?(account)

      plan = account.plan_to_pay_for
      reconcile = Reconcile.new(account:, **{ client: }.compact)
      change = reconcile.propose([ { op: "plan", price: plan.price_id } ], by:)
      reconcile.confirm(change, digest: change.digest)
    end

    # Accounts whose plan code was withdrawn and whose bill still lacks the
    # plan: the sweep's retries.
    def pending_accounts
      withdrawn = BillingCodeRedemption.where.not(withdrawn_at: nil).where("effect LIKE 'plan:%'").select(:account_id)
      Account.where(id: withdrawn).select { |account| needed?(account) }
    end

  end
end
