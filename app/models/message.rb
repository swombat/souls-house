class Message < ApplicationRecord

  include Discard::Model
  include Broadcastable
  include ObfuscatesId
  include JsonAttributes
  include SyncAuthorizable
  include Message::Attachable
  include Message::Moderatable
  include Message::Replayable
  include Message::Progress
  include Message::Streamable
  include Message::Revisioned
  include Message::ReplyAttention
  include Message::SafeguardLabel

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
  belongs_to :runtime_interaction, class_name: "AgentRuntimeInteraction", optional: true
  has_one :account, through: :chat
  has_one :message_dispatch
  has_one :rhythm_occurrence
  has_many :message_stone_revisions, dependent: :destroy
  has_many :stone_revisions, through: :message_stone_revisions

  attr_accessor :skip_content_validation
  attr_accessor :suppress_automatic_dispatch
  attr_reader :single_resident_response_triggered

  broadcasts_to :chat

  validates :role, inclusion: { in: %w[user assistant system tool] }
  validates :content, presence: true, unless: -> { role.in?(%w[assistant tool]) || skip_content_validation }
  validate :not_duplicate_of_last_message, on: :create
  validate :submission_identity_unchanged, on: :update

  scope :sorted, -> { order(created_at: :asc) }

  def self.search_in_account(account, query)
    return none if query.blank?

    joins(:chat)
      .where(chats: { account_id: account.id, discarded_at: nil })
      .where(discarded_at: nil)
      .where("messages.content ILIKE ?", "%#{sanitize_sql_like(query)}%")
      .where(role: %w[user assistant])
      .includes(:chat, :user, :agent)
      .order(created_at: :desc)
  end

  after_create :record_chat_message_time
  after_create :reopen_all_agents_for_initiation, if: :human_message_in_group_chat?
  after_create :accept_single_resident_dispatch, if: :human_message_in_group_chat?
  after_create_commit :trigger_single_resident_response, if: :human_message_in_group_chat?
  after_create_commit :advance_runtime_response_chain
  after_save_commit :refresh_chat_context_tokens, if: -> { role == "assistant" && saved_change_to_input_tokens? }

  def record_chat_message_time
    chat.with_lock do
      if chat.last_message_at.nil? || created_at > chat.last_message_at
        chat.update!(last_message_at: created_at)
      end
    end
  end
  private :record_chat_message_time

  # A human message in a room with exactly one resident wakes that resident,
  # from every entry point (web, app, API, opening message). With live
  # activity on, the wake is a durable "automatic" MessageDispatch written in
  # the transaction that accepts the message, so it is the same intent a
  # mention writes: discard cancels it before claim, a lost reservation lapses
  # to expired (no recovery; ask again), and the claim rechecks authority (#94 B). Rooms with
  # more residents keep explicit mentions; PostFromHuman skips mention
  # dispatch here so one send never makes two wakes.
  def accept_single_resident_dispatch
    return if suppress_automatic_dispatch
    return unless AgentRuntimeInteraction.live_activity_enabled?

    resident = chat.sole_resident
    return unless resident && chat.respondable?
    return unless resident.eligible_for_conversation?
    return unless Agents::InferenceAvailability.dispatchable?(resident)
    return if chat.agent_response_active?(resident)

    @single_resident_dispatch = MessageDispatch.accept!(message: self, target_agent_ids: [ resident.id ], kind: "automatic")
  end
  private :accept_single_resident_dispatch

  # Reserve after acceptance commits, inline, so the queued activity exists
  # before the send returns. A reservation that fails here leaves the
  # dispatch pending until it expires; the send is still accepted.
  #
  # With live activity off there is no durable run to reserve, so the room
  # keeps master's direct trigger. The two paths are exclusive: a dispatch is
  # only written while live activity is on.
  def trigger_single_resident_response
    return if suppress_automatic_dispatch
    if @single_resident_dispatch
      @single_resident_dispatch.reserve!
      @single_resident_response_triggered = @single_resident_dispatch.reserved?
    elsif !AgentRuntimeInteraction.live_activity_enabled?
      trigger_single_resident_directly
    end
  rescue StandardError => e
    Rails.logger.warn "[Message] #{id} accepted; sole-resident wake not reserved: #{e.class}: #{e.message}"
    @single_resident_response_triggered = false
  end
  private :trigger_single_resident_response

  def trigger_single_resident_directly
    chat.with_lock do
      return unless chat.respondable?

      resident = chat.sole_resident
      return unless resident&.eligible_for_conversation?
      return unless Agents::InferenceAvailability.dispatchable?(resident)
      return if chat.agent_response_active?(resident)

      @single_resident_response_triggered = chat.trigger_agent_response!(resident).present?
    end
  rescue Agent::RuntimeAvailability::Unavailable
    # A resident disabled during submission must not turn a saved message into
    # a failed send. Dispatch also rechecks availability before invoking it.
    @single_resident_response_triggered = false
  end
  private :trigger_single_resident_directly

  def advance_runtime_response_chain
    runtime_interaction&.advance_response_chain! if role == "assistant"
  end
  private :advance_runtime_response_chain

  json_attributes :role, :content, :thinking, :thinking_preview, :user_name, :user_avatar_url,
                  :progress_message, :progress_break_after, :progress_status, :progress_run_id, :runtime_interaction_id,
                  :completed, :created_at_formatted, :created_at_hour, :streaming,
                  :files_json, :stones_json, :content_html, :tools_used, :tool_status,
                  :author_name, :author_type, :author_colour, :input_tokens, :output_tokens,
                  :editable, :deletable,
                  :moderation_flagged, :moderation_severity, :moderation_scores,
                  :audio_source, :audio_url,
                  :voice_available, :voice_audio_url,
                  :reasoning_skip_reason, :reasoning_skip_reason_label, :rhythm_provenance, :safeguard,
                  :runtime_model_label do |hash, options|
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

  # The model that actually produced a resident's answer, from the execution
  # record of its turn. It is fixed when the turn runs, so later changes to the
  # conversation's selection never relabel an earlier answer.
  def runtime_model_label
    return unless role == "assistant" && agent_id && runtime_interaction

    AgentRuntimeInteraction.model_label_for(runtime_interaction.model)
  end

  def rhythm_provenance
    occurrence = rhythm_occurrence
    return unless occurrence

    {
      title: occurrence.rhythm_title, creator_name: occurrence.creator_label,
      creator_type: role == "assistant" ? "agent" : "user",
      scheduled_for: occurrence.scheduled_for.iso8601, manual: occurrence.manual,
      rhythm_url: occurrence.rhythm && Rails.application.routes.url_helpers.account_rhythm_path(chat.account, occurrence.rhythm)
    }
  end

  def stones_json
    stone_revisions.includes(:stone).map do |revision|
      stone = revision.stone
      {
        id: revision.to_param, title: revision.title, number: revision.number,
        url: "/stones/#{stone.public_token}/revisions/#{revision.number}",
        latest_url: "/stones/#{stone.public_token}",
        newer_revision_available: stone.latest_revision.number > revision.number,
        withdrawn: stone.withdrawn?
      }
    end
  end

  def user_name
    user&.full_name
  end

  def user_avatar_url
    user&.avatar_url
  end

  def author_name
    if safeguard_labelled?
      SafeguardNoticeRenderer::HOUSE_AUTHOR_NAME
    elsif agent.present?
      agent.name
    elsif user.present?
      user.full_name.presence || user.email_address.split("@").first
    elsif role == "system"
      SafeguardNoticeRenderer::HOUSE_AUTHOR_NAME
    else
      "System"
    end
  end

  def author_type
    if safeguard_labelled?
      "system"
    elsif agent.present?
      "agent"
    elsif user.present?
      "human"
    else
      "system"
    end
  end

  def author_colour
    if safeguard_labelled?
      nil
    elsif agent.present?
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

  # A labelled safeguard script is never read aloud in the resident's voice.
  def voice_available
    role == "assistant" && agent&.voiced? && !safeguard_labelled?
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

  # A human edit or discard, serialized against this message's wake (#94 B,
  # step 4b-ii) under the dispatch lock, so it lands wholly before or wholly
  # after the wake is reserved or claimed. An edit cancels a wake that has not
  # been reserved and never retargets it; a discard also cancels reserved,
  # unclaimed runs.
  def update_as_author(attributes)
    with_dispatch_lock do
      updated = update(attributes)
      message_dispatch&.source_edited! if updated && saved_change_to_content?
      updated
    end
  end

  def discard_as_author!
    with_dispatch_lock do
      discard!
      message_dispatch&.source_discarded!
    end
  end

  def deletable
    deletable_by?(Current.user)
  end

  private

  def human_message_in_group_chat?
    role == "user" && user_id.present? && chat.manual_responses?
  end

  def with_dispatch_lock(&block)
    message_dispatch ? message_dispatch.with_lock(&block) : transaction(&block)
  end

  def reopen_all_agents_for_initiation
    chat.chat_agents.closed_for_initiation.update_all(closed_for_initiation_at: nil)
  end

  def refresh_chat_context_tokens
    chat.recalculate_context_tokens!
  end

  # A retry is judged against what was first submitted (ADR 0004), so the
  # identity outlives every edit, discard and restore.
  def submission_identity_unchanged
    %w[client_message_id submission_digest].each do |attribute|
      errors.add(attribute, "cannot change once sent") if attribute_changed?(attribute)
    end
  end

  def not_duplicate_of_last_message
    return if content.blank? || chat.nil?

    # Only check against persisted messages (exclude any unsaved records in the association)
    # Use reorder to override any default scope ordering
    last_message = chat.messages.kept.where.not(id: nil).reorder(created_at: :desc).first
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
      no_intra_emphasis: true,
      fenced_code_blocks: true,
      tables: true,
      strikethrough: true
    )
    renderer.render(content || "").html_safe
  end

end
