module Api
  module V1
    # The accounts the person is a confirmed member of (enabled accounts only),
    # with their role in each. Listing grants nothing: every other request is
    # still scoped by the credential and account_id. Needs no selected account.
    # Person credentials only.
    class AccountsController < BaseController

      include ApiV1SelfEndpoints

      def index
        render json: { accounts: self_usable_memberships(current_api_user).map { |membership| self_listed_account_json(membership) } }
      end

    end
  end
end
