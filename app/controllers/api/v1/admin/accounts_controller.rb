module Api
  module V1
    module Admin
      class AccountsController < BaseController

        def index
          render json: report.accounts
        end

      end
    end
  end
end
