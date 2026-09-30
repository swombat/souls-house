module ConversationDraftActions

  extend ActiveSupport::Concern

  included do
    before_action { response.headers["Cache-Control"] = "no-store" }
    rescue_from ConversationDraft::Conflict do |error|
      render json: { error: error.message, draft: error.draft.as_json }, status: :conflict
    end
    rescue_from ActiveRecord::RecordInvalid do |error|
      render json: { errors: error.record.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def show
    render json: { draft: conversation_draft.as_json }
  end

  def update
    unless params[:content].is_a?(String)
      return render json: { error: "content must be text" }, status: :unprocessable_entity
    end

    conversation_draft.replace!(content: params[:content], revision: params[:revision])
    render json: { draft: conversation_draft.as_json }
  end

end
