class Message < ApplicationRecord

  include Broadcastable
  include ObfuscatesId
  include JsonAttributes
  include SyncAuthorizable
  include Message::Attachable
  include Message::Moderatable
  include Message::Replayable
  include Message::Streamable

  belongs_to :ai_model, optional: true
  belongs_to :parent_tool_call, class_name: "ToolCall", foreign_key: :tool_call_id, optional: true
  has_many :tool_calls, dependent: :destroy
  has_many :tool_results, through: :tool_calls, source: :result

  # Preserve the historical string-based API and mass assignment.
  attribute :thinking, :string

  def thinking
    thinking_text
  end

  def thinking=(value)
    text_value = value.respond_to?(:text) ? value.text : value
    self.thinking_text = text_value
  end

  belongs_to :chat, touch: true
  belongs_to :user, optional: true
  belongs_to :agent, optional: true
  has_one :account, through: :chat

  attr_accessor :skip_content_validation

  broadcasts_to :chat

  validates :role, inclusion: { in: %w[user assistant system tool] }
  validates :content, presence: true, unless: -> { role.in?(%w[assistant tool]) || skip_content_validation }
  validate :not_duplicate_of_last_message, on: :create

  scope :sorted, -> { order(created_at: :asc) }

  def self.search_in_account(account, query)
    return none if query.blank?

    joins(:chat)
      .where(chats: { account_id: account.id, discarded_at: nil })
      .where("messages.content ILIKE ?", "%#{sanitize_sql_like(query)}%")
      .where(role: %w[user assistant])
      .includes(:chat, :user, :agent)
      .order(created_at: :desc)
  end

  after_create :reopen_all_agents_for_initiation, if: :human_message_in_group_chat?
  after_save_commit :refresh_chat_context_tokens, if: -> { role == "assistant" && saved_change_to_input_tokens? }

  json_attributes :role, :content, :thinking, :thinking_preview, :user_name, :user_avatar_url,
                  :completed, :created_at_formatted, :created_at_hour, :streaming,
                  :files_json, :content_html, :tools_used, :tool_status,
                  :author_name, :author_type, :author_colour, :input_tokens, :output_tokens,
                  :editable, :deletable,
                  :moderation_flagged, :moderation_severity, :moderation_scores,
                  :audio_source, :audio_url,
                  :voice_available, :voice_audio_url,
                  :reasoning_skip_reason, :reasoning_skip_reason_label do |hash, options|
    if options&.dig(:include_ruby_llm_telemetry) && (telemetry = ruby_llm_telemetry)
      hash["ruby_llm_telemetry"] = telemetry
    end

    hash
  end

  def completed?
    # User messages are always completed
    # Assistant messages are completed if they have content or attachments
    role == "user" || (role == "assistant" && (content.present? || attachments.attached?))
  end

  alias_method :completed, :completed?

  def user_name
    user&.full_name
  end

  def user_avatar_url
    user&.avatar_url
  end

  def author_name
    if agent.present?
      agent.name
    elsif user.present?
      user.full_name.presence || user.email_address.split("@").first
    else
      "System"
    end
  end

  def author_type
    if agent.present?
      "agent"
    elsif user.present?
      "human"
    else
      "system"
    end
  end

  def author_colour
    if agent.present?
      agent.colour
    elsif user.present?
      user.chat_colour
    end
  end

  def created_at_formatted
    created_at.strftime("%l:%M %p")
  end

  def created_at_hour
    created_at.strftime("%Y-%m-%d %l:00")
  end

  def content_html
    render_markdown
  end

  def thinking_preview
    return nil if thinking.blank?
    thinking.truncate(80, separator: " ")
  end

  def voice_available
    role == "assistant" && agent&.voiced?
  end

  def ruby_llm_telemetry
    return unless role == "assistant"
    return if agent&.externally_hosted?

    token_usage = {
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cache_read_tokens: cached_tokens,
      cache_write_tokens: cache_creation_tokens
    }

    telemetry = {
      model: model_id_string.presence || chat.model_id,
      instrumentation_complete: token_usage.values.none?(&:nil?),
      **token_usage
    }

    layout = {
      prompt_layout_version: prompt_layout_version,
      stable_prompt_bytes: stable_prompt_bytes,
      transcript_prompt_bytes: transcript_prompt_bytes,
      envelope_prompt_bytes: envelope_prompt_bytes,
      stable_prompt_sha256: stable_prompt_sha256
    }
    telemetry.merge!(layout) if layout.values.any?(&:present?)
    telemetry
  end

  def content_for_speech
    Message::SpeechText.new(content).to_s
  end

  def owned_by?(user)
    role == "user" && (user_id == user&.id || user&.site_admin)
  end

  alias_method :editable_by?, :owned_by?
  alias_method :deletable_by?, :owned_by?

  def editable
    editable_by?(Current.user)
  end

  def deletable
    deletable_by?(Current.user)
  end

  private

  def human_message_in_group_chat?
    role == "user" && user_id.present? && chat.manual_responses?
  end

  def reopen_all_agents_for_initiation
    chat.chat_agents.closed_for_initiation.update_all(closed_for_initiation_at: nil)
  end

  def refresh_chat_context_tokens
    chat.recalculate_context_tokens!
  end

  def not_duplicate_of_last_message
    return if content.blank? || chat.nil?

    # Only check against persisted messages (exclude any unsaved records in the association)
    # Use reorder to override any default scope ordering
    last_message = chat.messages.where.not(id: nil).reorder(created_at: :desc).first
    return if last_message.nil?

    if last_message.content == content
      errors.add(:base, :duplicate_message, message: "This message was already sent")
    end
  end

  def render_markdown
    renderer = Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new(
        filter_html: true,
        safe_links_only: true,
        hard_wrap: true
      ),
      autolink: true,
      fenced_code_blocks: true,
      tables: true,
      strikethrough: true
    )
    renderer.render(content || "").html_safe
  end

end
