module Api
  module V1
    module Admin
      class UsersController < BaseController

        def index
          render json: report.users
        end

      end
    end
  end
end
