class MessagesController < ApplicationController

  require_feature_enabled :chats
  before_action :set_chat, only: [ :index, :create ]
  before_action :set_message, only: [ :update, :destroy ]
  before_action :require_respondable_chat, only: :create
  before_action :authorize_message_modification, only: [ :update, :destroy ]

  def index
    @messages = @chat.messages_page(before_id: params[:before_id])
    @has_more = @messages.any? && @chat.messages.where("id < ?", @messages.first.id).exists?
    interaction_costs = InteractionCostsByMessage.new(chat: @chat, messages: @messages).call

    render json: {
      messages: @messages.map { |message| message_json(message, interaction_costs[message.id]) },
      has_more: @has_more,
      oldest_id: @messages.first&.to_param
    }
  end

  def create
    @message = @chat.messages.build(
      message_params.merge(user: Current.user, role: "user")
    )
    @message.attachments.attach(params[:files]) if params[:files].present?

    if params[:audio_signed_id].present?
      begin
        @message.audio_recording.attach(params[:audio_signed_id])
        @message.audio_source = true
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        Rails.logger.warn "Invalid audio_signed_id for message in chat #{@chat.id}"
      end
    end

    if @message.save
      audit("create_message", @message, **message_params.to_h)
      if @chat.manual_responses?
        @chat.trigger_mentioned_agents!(@message.content)
      end

      respond_to do |format|
        format.html { redirect_to account_chat_path(@chat.account, @chat) }
        format.json { render json: @message, status: :created }
      end
    elsif @message.errors.added?(:base, :duplicate_message)
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
    if @message.update(message_params)
      audit(:update_message, @message, old_content: old_content, new_content: @message.content)
      head :ok
    else
      render json: { errors: @message.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    audit(:delete_message, @message, content: @message.content)
    @message.destroy!
    head :ok
  end

  private

  def set_chat
    @chat = current_account.chats.find(params[:chat_id])
  end

  def set_message
    @message = Message.find(params[:id])
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
