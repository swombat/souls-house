module Api
  module V1
    # The accounts the key's person is a confirmed member of, with their role
    # in each. Listing grants nothing: every other request is still scoped by
    # the key. Human keys only.
    class AccountsController < BaseController

      include ApiV1HumanSelf

      def index
        render json: { accounts: confirmed_memberships_for(current_api_user).map { |membership| account_json(membership) } }
      end

    end
  end
end
