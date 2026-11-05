module Api
  module V1
    # The account's visual tag palette. GET lists it (a resident may name an
    # account where it is a guest). PATCH /api/v1/visual_tags/:id switches
    # one tag's pins_to_top, the only thing it changes: a resident in its
    # home account only, a person where they may manage the account. Label,
    # icon and colour stay with /api/v1/account/visual_tags (people only).
    class VisualTagsController < BaseController

      before_action :set_tag, only: :update

      def index
        render json: { visual_tags: requested_account.visual_tags.palette_order.map(&:as_json) }
      end

      def update
        unless params.key?(:pins_to_top) && [ true, false ].include?(params[:pins_to_top])
          return render json: { error: "Provide pins_to_top (true or false)" }, status: :unprocessable_entity
        end

        @tag.update!(pins_to_top: params[:pins_to_top])
        audit(@tag)
        render json: { visual_tag: @tag.as_json }
      rescue ActiveRecord::RecordInvalid => error
        render json: { error: error.record.errors.full_messages.to_sentence, errors: error.record.errors.to_hash },
               status: :unprocessable_entity
      end

      private

      def set_tag
        account = if current_api_agent
          raise ActiveRecord::RecordNotFound if params[:account_id].present? && params[:account_id] != current_api_account.to_param

          current_api_account
        else
          human_account!(requested_account)
        end
        @tag = VisualTag.resolve_for(account, params[:id])
        return if current_api_agent || account.manageable_by?(current_api_user)

        render json: { error: "You don't have permission to manage this account" }, status: :forbidden
      end

      def audit(tag)
        by = if current_api_agent
          { agent_id: current_api_agent.id, agent_name: current_api_agent.name, api_key_id: @current_api_key&.id, by: "resident" }
        else
          api_credential_audit_data
        end
        AuditLog.create!(
          user: current_api_agent ? nil : current_api_user,
          account: tag.account,
          action: "update_visual_tag",
          auditable: tag,
          data: { label: tag.label, pins_to_top: tag.pins_to_top?, **by },
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
      end

    end
  end
end
