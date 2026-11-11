module WorkStatusResponse

  extend ActiveSupport::Concern

  included do
    rescue_from Chat::WorkStatus::Invalid do |error|
      render json: { error: error.message }, status: :unprocessable_entity
    end
    rescue_from Chat::WorkStatus::Conflict do |error|
      render json: { error: error.message, work_status: @chat.work_status_json }, status: :conflict
    end
  end

  private

  def update_work_status(agent: nil, user: nil)
    unless params.key?(:state)
      raise Chat::WorkStatus::Invalid, "state must be provided (or null to stop tracking)"
    end
    @chat.with_work_status_authority!(agent: agent, user: user) do
      changed = @chat.change_work_status!(state: params[:state], reason: params[:reason],
        expected_revision: params[:expected_revision])
      if changed
        AuditLog.create!(user: agent ? nil : user, account: @chat.account, action: "update_work_status", auditable: @chat,
          data: { state: @chat.work_status, revision: @chat.work_status_revision,
                  by: agent ? "resident" : "human", agent_id: agent&.id },
          ip_address: request.remote_ip, user_agent: request.user_agent)
      end
    end
    render json: { work_status: @chat.work_status_json, updated_at: @chat.updated_at.iso8601(6) }
  end

end
