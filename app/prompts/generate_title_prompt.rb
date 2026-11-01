# frozen_string_literal: true

class GenerateTitlePrompt

  MAX_MESSAGES = 12
  MAX_MESSAGE_LENGTH = 240

  # Without a provider the call runs on the account's own OpenRouter key
  # (UtilityInference.title). With one, it runs on the house's key, pinned to
  # that provider (TitleSweepJob's retry).
  def initialize(chat:, model: UtilityInference::TITLE_MODEL, provider: nil)
    @model = model
    @provider = provider
    @chat = chat
  end

  def generate_title
    response = if @provider
      UtilityInference.house_chat(model: @model, provider: @provider, max_tokens: 100, **render)
    else
      UtilityInference.title(account: chat.account, model: @model, **render)
    end
    extract_title(response)&.squish
  end

  private

  attr_reader :chat

  def render
    %i[system user].index_with do |role|
      PromptTemplate.render("generate_title", role, messages: build_conversation_lines, model: @model)
    end
  end

  def build_conversation_lines
    chat.messages.kept
        .order(:created_at)
        .limit(MAX_MESSAGES)
        .map { |message| format_message_line(message) }
        .compact
  end

  def format_message_line(message)
    content = message.content.to_s.strip
    return if content.blank?
    # A labelled safeguard script should not name the conversation.
    return if message.safeguard_labelled?

    label = case message.role
    when "user" then "User"
    when "assistant" then "Assistant"
    when "system" then "System"
    else
      message.role.to_s.titleize
    end

    truncated_content = content.truncate(MAX_MESSAGE_LENGTH)
    "#{label}: #{truncated_content}"
  end

  def extract_title(response)
    return if response.blank?

    if response.is_a?(Hash)
      response.dig("choices", 0, "message", "content")
    else
      response
    end
  end

end
