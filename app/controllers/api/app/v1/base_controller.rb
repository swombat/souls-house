module Api
  module App
    module V1
      # Base for the native-app API (issue #94). Bearer access tokens from
      # Doorkeeper; authority is the token's user, its device session still
      # live, and (from PR B) current confirmed membership of the account the
      # request names. Errors use one shape: { error: { code, message, details } }.
      class BaseController < ActionController::API

        before_action :authenticate_app_token!

        rescue_from ActiveRecord::RecordNotFound do
          render_error :not_found, "not_found", "Not found"
        end

        private

        attr_reader :current_user, :current_app_session

        def authenticate_app_token!
          token = doorkeeper_token
          if token&.accessible? && token.acceptable?(:chat) && token.app_session&.revoked_at.nil?
            @current_app_session = token.app_session
            @current_user = @current_app_session.user
            @current_app_session.touch_last_used!
          else
            render_error :unauthorized, "unauthorized", "Sign in again"
          end
        end

        def render_error(status, code, message, details = {})
          render json: { error: { code: code, message: message, details: details } }, status: status
        end

      end
    end
  end
end
