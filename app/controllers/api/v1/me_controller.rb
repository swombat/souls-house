module Api
  module V1
    # The credential's own person: GET reads their profile and settings, PATCH
    # changes them. Mirrors UsersController#edit/#update. Person credentials
    # only; needs no selected account. Password and email are deliberately not
    # here.
    class MeController < BaseController

      include ApiV1SelfEndpoints

      wrap_parameters false

      def show
        render json: { user: self_user_json(current_api_user) }
      end

      def update
        user = current_api_user
        params_for_user, params_for_profile = User.split_settings_params(settings_params)

        if user.update_settings(params_for_user, params_for_profile)
          self_audit_with_changes(user.settings_audit_action(avatar_updated: false), user)
          render json: { user: self_user_json(user) }
        else
          render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      # The web's settings params, minus avatar (PUT /me/avatar) and the
      # legacy nested forms. default_account_id is the account's public id,
      # as listed under accounts; blank clears the choice.
      def settings_params
        permitted = params.permit(:first_name, :last_name, :timezone, :theme, :chat_colour, :theme_hue, :default_account_id)
        permitted[:default_account_key] = permitted.delete(:default_account_id) if permitted.key?(:default_account_id)
        permitted
      end

    end
  end
end
