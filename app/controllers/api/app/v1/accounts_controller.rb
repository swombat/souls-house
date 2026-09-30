module Api
  module App
    module V1
      # Lists the accounts the user is a confirmed member of. Listing grants
      # nothing: every other request re-checks membership of the account it names.
      class AccountsController < BaseController

        def index
          memberships = current_user.confirmed_memberships.joins(:account).merge(Account.enabled).includes(:account).order(:created_at)
          render json: { accounts: memberships.map { |m| Presenter.account(m.account, m) } }
        end

      end
    end
  end
end
