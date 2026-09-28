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

        # Not doorkeeper_token: Doorkeeper's authenticate retires the parent
        # refresh token for any row it finds, even a revoked or expired one, so
        # a rejected superseded bearer would end the parent's lost-response
        # retry grace. Validate first; only a usable bearer retires its parent,
        # and under the family lock the token endpoint also holds.
        def authenticate_app_token!
          presented = Doorkeeper::OAuth::Token.from_request(request, *Doorkeeper.config.access_token_methods)
          token = Doorkeeper::AccessToken.by_token(presented) if presented.present?
          return render_error(:unauthorized, "unauthorized", "Sign in again") unless usable?(token)

          if token.previous_refresh_token.present?
            AppSession.transaction do
              AppSession.lock.find(token.app_session_id)
              token.reload
              token.revoke_previous_refresh_token! if usable?(token)
            end
            return render_error(:unauthorized, "unauthorized", "Sign in again") unless usable?(token)
          end

          @current_app_session = token.app_session
          @current_user = @current_app_session.user
          @current_app_session.touch_last_used!
        end

        def usable?(token)
          token&.accessible? && token.acceptable?(:chat) && token.app_session.present? && !token.app_session.revoked?
        end

        def render_error(status, code, message, details = {})
          render json: { error: { code: code, message: message, details: details } }, status: status
        end

      end
    end
  end
end
