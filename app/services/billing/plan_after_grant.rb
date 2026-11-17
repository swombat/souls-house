module Billing
  # When a grant that gave the account its plan is withdrawn, the account
  # pays for its plan again: the bill it already has takes back the plan's
  # line, and the resident the plan includes stays on it at $0. This is the
  # model with the grant gone (plan_includes_resident_test: you pay for the
  # plan and it includes one Small), so a withdrawn grant never leaves a $0
  # resident with no plan paid for. Site Admin's withdraw step says so before
  # it is pressed. An account still given a plan at least as high as the one
  # it would pay for, with no bill, or already paying for a plan, is left as
  # it is.
  module PlanAfterGrant

    module_function

    # Returns the applied BillChange, or nil when there was nothing to put back.
    def restore!(account, by:, client: nil)
      plan = account.plan_to_pay_for
      return nil unless plan && Reconcile.applies?(account)
      return nil if AccountSubscription.live.where(account:).exists?
      return nil unless ResidentSubscription.live.where(account:, rate: "included").exists?

      reconcile = Reconcile.new(account:, **{ client: }.compact)
      change = reconcile.propose([ { op: "plan", price: plan.price_id } ], by:)
      reconcile.confirm(change, digest: change.digest)
    end

  end
end
