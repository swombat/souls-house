module WorkCompletionResponse

  extend ActiveSupport::Concern
  include WorkStatusResponse

  included do
    rescue_from ActiveRecord::RecordInvalid do |error|
      render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  private

  def perform_completion_action(action, agent: nil, user: nil)
    if agent && action.in?(%w[accept grant revoke])
      return render json: { error: "Only a human member of this house can authorise completion" }, status: :forbidden
    end
    @chat.with_completion_authority!(agent: agent, user: user) do
      case action
      when "show"
        # Read under the same authority boundary as writes.
      when "create"
        @completion = @chat.submit_completion!(agent: agent, user: agent ? nil : user,
          expected_revision: params[:expected_revision], request_key: params[:request_key],
          fields: params.permit(*WorkCompletion::FIELDS).to_h)
      when "accept"
        @completion = @chat.work_completions.find(params[:id])
        @chat.accept_completion!(completion: @completion, user: user,
          expected_revision: params[:expected_revision], auto_close: params[:auto_close])
      when "grant"
        @chat.grant_completion_permission!(user: user, expected_revision: params[:expected_revision],
          auto_close: params[:auto_close])
      when "close"
        @completion = @chat.work_completions.find(params[:id])
        @chat.close_completion!(completion: @completion, expected_revision: params[:expected_revision],
          closing_agent: agent)
      when "revoke"
        @chat.send(:check_completion_revision!, params[:expected_revision])
        @chat.work_completion_permissions.available.update_all(revoked_at: Time.current)
      end
      unless action == "show"
        AuditLog.create!(user: agent ? nil : user, account: @chat.account,
          action: "work_completion_#{action}", auditable: @chat,
          data: { agent_id: agent&.id, revision: @chat.work_status_revision,
                  completion_id: @completion&.id },
          ip_address: request.remote_ip, user_agent: request.user_agent)
      end
      @completion ||= @chat.work_completions.order(id: :desc).first
      permission = @chat.work_completion_permissions.available.where(work_revision: @chat.work_status_revision).order(id: :desc).first
      @completion_payload = {
        work_status: @chat.work_status_json,
        completion: @completion&.as_work_json,
        permission: permission && { revision: permission.work_revision, auto_close: permission.auto_close },
        archived: @chat.archived?,
        updated_at: @chat.updated_at.iso8601(6)
      }
    end
    render json: @completion_payload
  end

end
