module Api
  module V1
    module Admin
      class SummariesController < BaseController

        def show
          render json: report.summary
        end

      end
    end
  end
end
