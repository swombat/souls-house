# Whether a new resident may be created in an account without paying for it.
#
# An account created while the site's billing switch is on has
# billing_required set (a site admin can change it per account). Every new
# resident in such an account, born or imported, needs a plan. Residents the
# account already has are untouched: they stay on the house.
#
# Paying at creation isn't built yet, so until it is a billing account is
# refused here with a plain reason, before anything is committed. With the
# switch off nobody meets this.
module Billing
  class BirthGate

    class Refused < Agents::HostedProvisioning::ConfigurationError; end

    NOT_OPEN = "New residents in this account need a plan, and paying for one when you create a resident " \
               "isn't open yet. Ask a site admin.".freeze

    def self.refusal(account)
      return nil unless account&.billing_required?

      NOT_OPEN
    end

    def self.refuse!(account)
      reason = refusal(account)
      raise Refused, reason if reason
    end

  end
end
