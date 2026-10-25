# Whether a new resident may be created in an account without paying for it.
#
# An account created while the site's billing switch is on has
# billing_required set (a site admin can change it per account). Every new
# resident in such an account, born or imported, needs a plan. Residents the
# account already has are untouched: they stay on the house.
#
# A birth in such an account is paid for as the creation wizard's last step
# (Billing::PaidBirth). Every other route to a new resident (a birth through
# the API, an archive or GitHub import) is refused here with a plain reason,
# before anything is committed. With the switch off nobody meets this.
module Billing
  class BirthGate

    class Refused < Agents::HostedProvisioning::ConfigurationError; end

    NOT_OPEN = "New residents in this account need a plan, and paying for one isn't open on this house yet. " \
               "Ask a site admin.".freeze
    NEEDS_PLAN = "New residents in this account need a plan. Create them on the website, where the last step " \
                 "sets one up.".freeze
    IMPORT_NOT_OPEN = "New residents in this account need a plan, and paying for an imported resident isn't " \
                      "available yet. Ask a site admin.".freeze

    def self.requires_plan?(account) = account&.billing_required? || false

    # Why the creation wizard can't be completed at all; nil when it can
    # (with a Plan step when the account pays).
    def self.wizard_refusal(account)
      NOT_OPEN if requires_plan?(account) && !Billing.configured?
    end

    # For births that don't pay at creation.
    def self.unpaid_refusal(account)
      NEEDS_PLAN if requires_plan?(account)
    end

    def self.refuse_unpaid!(account)
      reason = unpaid_refusal(account)
      raise Refused, reason if reason
    end

    def self.import_refusal(account)
      IMPORT_NOT_OPEN if requires_plan?(account)
    end

  end
end
