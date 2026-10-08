module Api
  module V1
    module Accounts
      # Creating, editing and removing the account's visual tags, as
      # accounts/visual_tags does on the web (manager). Listing stays at
      # GET /api/v1/visual_tags.
      class VisualTagsController < BaseController

        include ApiAccountAdministration

        before_action :require_account_manager!

        def create
          tag = @account.visual_tags.create!(visual_tag_params)
          audit(:create_visual_tag, tag)
          render json: { visual_tag: tag.as_json }, status: :created
        rescue ActiveRecord::RecordInvalid => error
          render_invalid(error.record)
        end

        def update
          tag = VisualTag.resolve_for(@account, params[:id])
          tag.update!(visual_tag_params)
          audit_with_changes(:update_visual_tag, tag)
          render json: { visual_tag: tag.as_json }
        rescue ActiveRecord::RecordInvalid => error
          render_invalid(error.record)
        end

        def destroy
          tag = VisualTag.resolve_for(@account, params[:id])
          tag.destroy!
          audit(:destroy_visual_tag, tag)
          render json: { removed: tag.as_json }
        rescue ActiveRecord::RecordNotDestroyed => error
          render_invalid(error.record)
        rescue ActiveRecord::InvalidForeignKey
          render json: { error: "This tag was selected while it was being removed. Please try again." }, status: :conflict
        end

        private

        def visual_tag_params
          params.slice(:label, :icon, :colour).permit(:label, :icon, :colour)
        end

      end
    end
  end
end
