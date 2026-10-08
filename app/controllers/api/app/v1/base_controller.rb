module Api
  module App
    module V1
      # Base for the native-app API (issue #94). Bearer access tokens from
      # Doorkeeper; authority is the token's user, its device session still
      # live, and (from PR B) current confirmed membership of the account the
      # request names. Errors use one shape: { error: { code, message, details } }.
      class BaseController < ActionController::API

        before_action :authenticate_app_token!

        # Hashids::InputError: a malformed obfuscated id is a missing record, not a 500.
        rescue_from ActiveRecord::RecordNotFound, Hashids::InputError do
          render_error :not_found, "not_found", "Not found"
        end

        private

        attr_reader :current_user, :current_app_session

        def authenticate_app_token!
          @current_app_session = AppAccessTokenAuthenticator.authenticate(request)
          return render_error(:unauthorized, "unauthorized", "Sign in again") unless @current_app_session

          @current_user = @current_app_session.user
        end

        # Authority is the token's user intersected with *current* confirmed
        # membership of the account the request names, checked on every request.
        # An account or conversation outside that is 404, never 403, so the API
        # doesn't confirm that it exists.
        def accessible_accounts
          current_user.confirmed_accounts
        end

        def find_account!(id)
          accessible_accounts.find(id)
        end

        def find_conversation!(id)
          Chat.app_accessible_to(current_user).find(id)
        end

        # Parses an integer query parameter. Renders a 422 and returns nil when
        # it is malformed or out of range, so callers can `or return`.
        def bounded_integer(name, default:, min:, max: nil)
          raw = params[name]
          if raw.blank?
            return default unless default == :required

            render_error :unprocessable_entity, "invalid_parameter", "#{name} is required", { parameter: name.to_s }
            return
          end

          value = Integer(raw.to_s, 10, exception: false)
          return value if value && value >= min && (max.nil? || value <= max)

          range = max ? "#{min}..#{max}" : ">= #{min}"
          render_error :unprocessable_entity, "invalid_parameter", "#{name} must be an integer #{range}", { parameter: name.to_s }
          nil
        end

        # The web's audit record for the same action, tagged with the device.
        def audit(action, auditable, **data)
          AuditLog.create!(
            user: current_user,
            account: (auditable.is_a?(Chat) ? auditable : auditable.try(:chat))&.account,
            action: action,
            auditable: auditable,
            data: data.merge(app_session_id: current_app_session.id),
            ip_address: request.remote_ip,
            user_agent: request.user_agent
          )
        end

        # Storage URLs (disk service in development and test) are built for
        # this request's origin.
        def with_storage_urls(&)
          ActiveStorage::Current.set(url_options: { protocol: request.protocol, host: request.host, port: request.optional_port }, &)
        end

        # One error shape. The request id is also in the X-Request-Id header.
        def render_error(status, code, message, details = {})
          render json: { error: { code: code, message: message, details: details, request_id: request.request_id } }, status: status
        end

      end
    end
  end
end
