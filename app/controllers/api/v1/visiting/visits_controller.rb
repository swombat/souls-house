module Api
  module V1
    module Visiting
      class VisitsController < BaseController

        before_action :authenticate_visit!

        def show
          render json: current_admission.status_json
        end

        # The visitor leaves: every seat closes, open wakes end.
        def destroy
          current_admission.end!(by: "visitor")
          render json: current_admission.reload.as_json
        end

      end
    end
  end
end
