module Api
  module V1
    # Many conversations in one request, for a person's credential: the web
    # sidebar's Actions menu (Chats::BulkActionsController) over the API.
    # Scoped to the request's account; IDs outside it are skipped, not errors.
    class ConversationBulkActionsController < BaseController

      include ApiHumanConversation

      before_action :require_human_actor!
      before_action :require_chats_feature!

      rescue_from ConversationBulk::InvalidIds do |error|
        render json: { error: error.message }, status: :unprocessable_entity
      end

      # POST /api/v1/conversations/bulk/mark_read
      #   { through_message_ids: { conversation_id => message_id } }: each
      #     through the message given, as the web's eye does; or
      #   { conversation_ids: [...] }: each through its latest message at
      #     the moment the request runs, newer arrivals included.
      def mark_read
        account = human_account!(current_api_account)
        raw = params[:through_message_ids]
        if raw.present? == params[:conversation_ids].present?
          render json: { error: "Provide exactly one of through_message_ids or conversation_ids" }, status: :unprocessable_entity
          return
        end

        acted = if raw
          cutoffs = ConversationBulk.decode_cutoffs(raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h : nil)
          ConversationBulk.mark_read!(chats: account.chats.visible_to(current_api_user).kept, user: current_api_user, cutoffs: cutoffs)
        else
          ids = ConversationBulk.decode_ids(conversation_ids_param)
          ConversationBulk.mark_read!(chats: account.chats.visible_to(current_api_user).kept.where(id: ids), user: current_api_user)
        end
        audit_human_action("bulk_dismiss_reply_expectations", nil, account: account, conversation_ids: acted)
        render json: { conversation_ids: acted }
      end

      # PATCH /api/v1/conversations/bulk/visual_tag { conversation_ids: [...], visual_tag_id: "abc" | null }
      def visual_tag
        account = human_account!(current_api_account)
        unless params.key?(:visual_tag_id) && (params[:visual_tag_id].nil? || (params[:visual_tag_id].is_a?(String) && params[:visual_tag_id].present?))
          render json: { error: "visual_tag_id must be a nonblank public ID string or null" }, status: :unprocessable_entity
          return
        end

        ids = ConversationBulk.decode_ids(conversation_ids_param)
        tag = VisualTag.resolve_for(account, params[:visual_tag_id])
        changed = ConversationBulk.set_tag!(chats: account.chats.visible_to(current_api_user).kept.where(id: ids), tag: tag, by: current_api_user)
        audit_human_action("bulk_set_visual_tag", nil, account: account, conversation_ids: changed, visual_tag_id: tag&.to_param)
        render json: { conversation_ids: changed, visual_tag: tag&.as_json }
      rescue ActiveRecord::InvalidForeignKey
        render json: {
          error: "This tag is no longer available. Refresh the palette and try again.",
          code: "visual_tag_unavailable"
        }, status: :conflict
      end

      private

      def conversation_ids_param
        raw = params[:conversation_ids]
        raw.is_a?(Array) ? raw : nil
      end

    end
  end
end
