class Messages::RetriesController < Messages::BaseController

  include RespondableChat

  before_action :require_respondable_chat

  def create
    respond_to do |format|
      format.html { redirect_to account_chat_path(@chat.account, @chat), alert: "Inline responses have been retired. Ask an available resident instead." }
      format.json { render json: { error: "Inline responses have been retired", code: "inline_runtime_retired" }, status: :conflict }
    end
  rescue => e
    respond_to do |format|
      format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "Retry failed: #{e.message}" }
      format.json { head :internal_server_error }
    end
  end

end
