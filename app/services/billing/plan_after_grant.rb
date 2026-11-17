module Billing
  # When a plan code that gave the account its plan is withdrawn, the account
  # pays for its own plan (the one it chose, else Companions) on the bill it
  # already has: the bill takes on that plan's line, and the resident the
  # plan includes keeps its included price ($0 for a Small, the difference
  # for a bigger one). This is A's model with the grant gone
  # (plan_includes_resident_test). Site Admin's withdraw step names the plan
  # and the amount before it is pressed (preview).
  #
  # Only a withdrawal that recorded the intent (bill_plan_pending_since, set
  # by Site Admin's withdraw since this rule) is acted on; earlier withdrawals
  # were made under "subscriptions already bought are unchanged".
  #
  # With no card to pay the plan, the bill is set to end at the period's end
  # instead, and its residents fall asleep then, as when a plan ends; nothing
  # is charged. Stripe refusing for now (a bill in its trial, past due or
  # ending) leaves the intent for SweepJob to try again; it is cleared once
  # the plan is on, the bill is set to end, or the rule no longer applies.
  module PlanAfterGrant

    module_function

    def needed?(account, given: account.given_plan)
      return false if given || account.at_cost_holder?
      return false unless Reconcile.applies?(account)
      return false if AccountSubscription.live.where(account:).exists?
      return false unless ResidentSubscription.live.where(account:, rate: "included").exists?

      plan_for(account).purchasable?
    end

    # The account's own plan: the one it chose, else Companions.
    def plan_for(account) = AccountPlan.find(account.chosen_plan) || AccountPlan.default

    # What withdrawing this live plan redemption would put on the bill: the
    # plan, or nil when nothing would change. For Site Admin's dialog.
    def preview(redemption)
      account = redemption.account
      others = account.billing_code_redemptions.live.where.not(id: redemption.id).where("effect LIKE 'plan:%'")
        .pluck(:effect).map { |effect| BillingCode.plan_of(effect) }
      given = [ AccountPlan.find(account.granted_plan), *others ].compact.max
      return nil unless redemption.effect.start_with?("plan:") && needed?(account, given:)

      plan_for(account)
    end

    # Records the intent on a plan redemption just withdrawn and acts on it.
    def withdrawn!(redemption, by:, client: nil)
      return nil unless redemption.effect.start_with?("plan:") && !redemption.live?

      redemption.update!(bill_plan_pending_since: Time.current)
      restore!(redemption.account, by:, client:)
    end

    # Returns the BillChange (applied, or submitted and still being
    # confirmed), or nil when there was nothing to do. Raises when Stripe
    # refuses for now; the intent stays for the sweep.
    def restore!(account, by:, client: nil)
      pending = account.billing_code_redemptions.where.not(bill_plan_pending_since: nil)
      return nil unless pending.exists?
      unless needed?(account)
        pending.update_all(bill_plan_pending_since: nil)
        return nil
      end

      reconcile = Reconcile.new(account:, **{ client: }.compact)
      change = reconcile.propose(ops_for(account, client:), by:)
      change = reconcile.confirm(change, digest: change.digest)
      pending.update_all(bill_plan_pending_since: nil) if change.applied?
      change
    end

    # The plan on the bill when it can be paid (a card on the bill or the
    # customer, as Reconcile#fit! asks); otherwise the bill set to end.
    def ops_for(account, client:)
      client ||= Billing.client
      included = ResidentSubscription.live.where(account:, rate: "included").order(:id).first
      bill = client.v1.subscriptions.retrieve(included.stripe_subscription_id)
      if bill[:default_payment_method].present? || PaymentMethod.new(account:, client:).current.present?
        [ { op: "plan", price: plan_for(account).price_id } ]
      else
        [ { op: "end_bill", agent_id: included.agent_id } ]
      end
    end

    # The sweep's retries: accounts with a recorded intent.
    def pending_accounts
      Account.where(id: BillingCodeRedemption.where.not(bill_plan_pending_since: nil).select(:account_id))
    end

  end
end
