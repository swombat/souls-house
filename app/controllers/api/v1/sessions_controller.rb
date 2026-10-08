module Api
  module V1
    # The credential itself: who is acting, and sign this credential out.
    # Mirrors /api/app/v1/session and extends it to API keys.
    class SessionsController < BaseController

      def show
        render json: {
          user: { id: current_api_user.to_param, email_address: current_api_user.email_address },
          credential: credential_json
        }
      end

      # An app session is revoked like the app's own sign-out. A person's API key
      # deletes itself. A resident key cannot remove itself here.
      def destroy
        if app_token_request?
          @current_app_session.revoke!(:logout)
        elsif current_api_agent
          return render json: { error: "A resident key cannot sign itself out" }, status: :forbidden
        else
          audit_human_action("revoke_api_key", @current_api_key, account: @current_api_key.account, via: "self")
          @current_api_key.destroy!
        end
        head :no_content
      end

      private

      def credential_json
        if app_token_request?
          { type: "app_session", id: @current_app_session.to_param, device_label: @current_app_session.device_label }
        else
          {
            type: current_api_agent ? "resident_key" : "api_key",
            name: @current_api_key.name,
            prefix: @current_api_key.display_prefix,
            account_id: @current_api_key.account.to_param,
            resident_id: current_api_agent&.to_param
          }
        end
      end

    end
  end
end
