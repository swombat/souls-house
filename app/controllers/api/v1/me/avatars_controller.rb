module Api
  module V1
    module Me
      # Upload (multipart `avatar`) or remove the key's person's avatar.
      # Mirrors the avatar branch of UsersController#update and
      # Users::AvatarsController#destroy. Human keys only.
      class AvatarsController < BaseController

        include ApiV1HumanSelf

        def update
          return render(json: { errors: [ "Avatar is required" ] }, status: :unprocessable_entity) if params[:avatar].blank?

          user = current_api_user
          if user.update_settings({}, { avatar: params[:avatar] })
            audit_with_changes(user.settings_audit_action(avatar_updated: true), user)
            render json: { user: me_json(user) }
          else
            render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          current_api_user.profile&.avatar&.purge_later
          audit(:remove_avatar, current_api_user)

          render json: { success: true }
        end

      end
    end
  end
end
