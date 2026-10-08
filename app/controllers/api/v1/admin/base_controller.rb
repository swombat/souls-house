module Api
  module V1
    module Admin
      class BaseController < Api::V1::BaseController

        prepend_before_action :prevent_caching
        before_action :require_site_admin

        rescue_from ::Admin::MonitoringReport::InvalidInput do |error|
          render json: { error: error.message }, status: :unprocessable_entity
        end

        private

        def prevent_caching
          response.headers["Cache-Control"] = "no-store"
        end

        def require_site_admin
          unless @current_api_key && @current_api_key.agent_id.nil? && current_api_user&.is_site_admin?
            render json: { error: "A site-admin user API key is required" }, status: :forbidden
          end
        end

        def report
          @report ||= ::Admin::MonitoringReport.new(params)
        end

      end
    end
  end
end
