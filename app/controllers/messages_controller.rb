class MessagesController < ApplicationController

  require_feature_enabled :chats
  include DraftAuthorBinding
  before_action :require_matching_draft_author, only: :create
  before_action :set_chat, only: [ :index, :create ]
  before_action :set_message, only: [ :update, :destroy ]
  before_action :require_respondable_chat, only: :create
  before_action :authorize_message_modification, only: [ :update, :destroy ]

  def index
    @messages = @chat.messages_page(before_id: params[:before_id])
    @has_more = @messages.any? && @chat.messages.kept.where("id < ?", @messages.first.id).exists?
    interaction_costs = InteractionCostsByMessage.new(chat: @chat, messages: @messages).call

    render json: {
      messages: @messages.map { |message| message_json(message, interaction_costs[message.id]) },
      has_more: @has_more,
      oldest_id: @messages.first&.to_param
    }
  end

  def create
    draft = if params.key?(:draft_revision)
      # Drafts never use the account administrator's widened browsing authority.
      Current.user.confirmed_accounts.find(@chat.account_id)
      ConversationDraft.for(chat: @chat, user: Current.user)
    end

    # One acceptance transaction: the message, its audit, the draft's clear and
    # any wake. A stale draft raises Conflict before anything is written.
    result = Messages::PostFromHuman.new(
      chat: @chat,
      user: Current.user,
      content: message_params[:content],
      files: params[:files],
      audio_signed_id: params[:audio_signed_id],
      draft: draft,
      draft_revision: params[:draft_revision]
    ).call(on_persisted: ->(message) { audit("create_message", message, **message_params.to_h) })
    @message = result.message

    if result.created?
      respond_to do |format|
        format.html { redirect_to account_chat_path(@chat.account, @chat) }
        format.json { render json: @message.as_json.merge(draft ? { draft: draft.as_json } : {}), status: :created }
      end
    elsif result.dispatch_unavailable?
      # Nothing was saved: a send that mentions residents needs a durable wake,
      # and there is none to reserve while live activity is off (#94 B, 4b-ii).
      notice = "Residents can't be woken right now, so your message was not sent. Please try again shortly."
      respond_to do |format|
        format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: notice }
        format.json { render json: { errors: [ notice ], retryable: true }, status: :service_unavailable }
      end
    elsif result.duplicate?
      # Duplicate message - just refresh the page silently
      respond_to do |format|
        format.html { redirect_to account_chat_path(@chat.account, @chat) }
        format.json { render json: { duplicate: true }, status: :ok }
      end
    else
      respond_to do |format|
        format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "Failed to send message: #{@message.errors.full_messages.join(', ')}" }
        format.json { render json: { errors: @message.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  rescue ConversationDraft::Conflict => e
    render json: { errors: [ e.message ], draft: e.draft.as_json }, status: :conflict
  rescue StandardError => e
    error "Message creation failed: #{e.message}"
    error e.backtrace.join("\n")
    respond_to do |format|
      format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "Failed to send message: #{e.message}" }
      format.json { render json: { errors: [ e.message ] }, status: :unprocessable_entity }
    end
  end

  def update
    old_content = @message.content
    if @message.update_as_author(message_params)
      audit(:update_message, @message, old_content: old_content, new_content: @message.content)
      head :ok
    else
      render json: { errors: @message.errors.full_messages }, status: :unprocessable_entity
    end
  end

  # Delete is discard (#92): the row and its content stay, hidden from every
  # transcript and restorable by an admin. Repeating it is a no-op.
  def destroy
    unless @message.discarded?
      audit(:delete_message, @message, content: @message.content)
      @message.discard_as_author!
    end
    head :ok
  end

  private

  def set_chat
    @chat = current_account.chats.find(params[:chat_id])
  end

  def set_message
    # Only delete may find an already-discarded message, so a repeat is a no-op.
    @message = (action_name == "destroy" ? Message : Message.kept).find(params[:id])
    @chat = if Current.user.site_admin
      Chat.find(@message.chat_id)
    else
      Chat.where(id: @message.chat_id, account_id: Current.user.confirmed_account_ids).first!
    end
  end

  def message_params
    params.require(:message).permit(:content)
  end

  def message_json(message, interaction_cost = nil)
    message.as_json(include_ruby_llm_telemetry: Current.user&.site_admin).tap do |json|
      json["interaction_cost"] = interaction_cost if interaction_cost
    end
  end

  def require_respondable_chat
    return if @chat.respondable?

    respond_to do |format|
      format.html { redirect_back_or_to account_chat_path(@chat.account, @chat), alert: "This conversation is archived or deleted and cannot receive new messages" }
      format.json { render json: { error: "This conversation is archived or deleted" }, status: :unprocessable_entity }
    end
  end

  def authorize_message_modification
    head :forbidden unless @message.owned_by?(Current.user)
  end

end
