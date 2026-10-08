module Api
  module V1
    module Me
      # Upload (multipart `avatar`) or remove the person's avatar. Mirrors the
      # avatar branch of UsersController#update and
      # Users::AvatarsController#destroy. Person credentials only.
      class AvatarsController < BaseController

        include ApiV1SelfEndpoints

        def update
          return render_avatar_error("Avatar is required") if params[:avatar].blank?
          # Only a multipart file. A string would reach Active Storage as a
          # signed blob id and a hash as attachable attributes.
          return render_avatar_error("Avatar must be an uploaded image file") unless params[:avatar].is_a?(ActionDispatch::Http::UploadedFile)

          user = current_api_user
          if user.update_settings({}, { avatar: params[:avatar] })
            self_audit_with_changes(user.settings_audit_action(avatar_updated: true), user)
            render json: { user: self_user_json(user) }
          else
            render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          current_api_user.profile&.avatar&.purge_later
          audit_human_action(:remove_avatar, current_api_user, account: self_audit_account)

          render json: { success: true }
        end

        private

        def render_avatar_error(message)
          render json: { errors: [ message ] }, status: :unprocessable_entity
        end

      end
    end
  end
end
