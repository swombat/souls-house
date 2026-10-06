class Chat < ApplicationRecord

  include Discard::Model
  include Broadcastable
  include ObfuscatesId
  include SyncAuthorizable
  include JsonAttributes
  include Chat::Archivable
  include Chat::Forkable
  include Chat::Initiable

  belongs_to :ai_model, optional: true
  has_many :messages, -> { order(created_at: :asc) }, dependent: :destroy
  has_many :stones, dependent: :destroy
  has_many :conversation_drafts, dependent: :destroy
  include Chat::ModelSelection
  include Chat::Summarizable

  belongs_to :account
  belongs_to :visual_tag, optional: true
  validate :visual_tag_belongs_to_account
  belongs_to :active_whiteboard, class_name: "Whiteboard", optional: true

  has_many :chat_agents, dependent: :destroy
  has_many :agents, through: :chat_agents
  has_many :agent_runtime_interactions, dependent: :nullify
  validates :agents, length: { minimum: 1, message: "must include at least one resident" },
    if: -> { new_record? && manual_responses? }
  # Public creation helpers cannot start bare-model conversations. Historical
  # rows remain readable and editable through ordinary persistence.
  validates :manual_responses, inclusion: { in: [ true ], message: "must be enabled for new resident conversations" }, on: :conversation_creation

  json_attributes :title_or_default, :model_id, :model_label, :ai_model_name, :updated_at_formatted,
                  :updated_at_short, :activity_at, :message_count, :context_tokens, :cost_tokens, :reasoning_tokens, :web_access, :manual_responses,
                  :participants_json, :archived_at, :discarded_at, :archived, :discarded, :respondable, :summary do |hash, options|
    hash["visual_tag"] = visual_tag&.as_json
    hash.delete("visual_tag_id")
    # For sidebar format, only include attributes used by the chat list UI.
    if options&.dig(:as) == :sidebar_json
      hash.slice!(
        "id",
        "title",
        "title_or_default",
        "updated_at",
        "updated_at_short",
        "activity_at",
        "message_count",
        "context_tokens",
        "manual_responses",
        "participants_json",
        "visual_tag",
        "archived",
        "discarded"
      )
    end
    hash
  end

  def self.json_attrs_for(options = nil)
    return json_attrs unless options&.dig(:as) == :sidebar_json

    json_attrs - [
      :model_id,
      :model_label,
      :ai_model_name,
      :updated_at_formatted,
      :cost_tokens,
      :reasoning_tokens,
      :web_access,
      :archived_at,
      :discarded_at,
      :respondable,
      :summary
    ]
  end

  broadcasts_to :account

  # Historical model references and string-only selections are both supported.
  validate :model_must_be_present

  # Preserve model labels on historical and harness conversations.
  after_initialize :configure_defaults

  after_create_commit -> { GenerateTitleJob.perform_later(self) }, unless: :title?
  after_update_commit :refresh_reply_attention, if: :saved_change_to_discarded_at?

  scope :latest, -> { order(Arel.sql("COALESCE(chats.last_message_at, chats.created_at) DESC"), id: :desc) }
  # The native app's authority (issue #94): current confirmed membership of an
  # enabled account, with no site-admin widening. HTTP and cable share it.
  scope :app_accessible_to, ->(user) { kept.where(account_id: user.confirmed_accounts.select(:id)) }

  def activity_at
    last_message_at || created_at
  end

  def refresh_reply_attention
    ReplyExpectation.joins(:message).where(messages: { chat_id: id }).distinct.pluck(:user_id)
      .each { |uid| ReplyExpectation.refresh_for(uid) }
  end

  # Create chat with optional initial message
  # The opening message wakes residents the same way a later send does: a
  # room with one resident wakes it automatically (Message), and a room with
  # several wakes the residents the message @mentions, through the same
  # durable mention dispatch PostFromHuman writes. The dispatch is accepted in
  # this transaction and enqueued once every enclosing transaction commits.
  # While live activity is off there is no durable run to reserve, so the
  # conversation is still created and the mention simply doesn't wake anyone
  # (the person can ask again from the room).
  def self.create_with_message!(attributes, message_content: nil, user: nil, files: nil, agent_ids: nil, audio_signed_id: nil, automatic_response: true)
    transaction do
      chat = new(attributes)
      chat.agent_ids = agent_ids if agent_ids.present?
      chat.save!(context: :conversation_creation)

      if message_content.present? || (files.present? && files.any?)
        message = chat.messages.create!({
          content: message_content || "",
          role: "user",
          user: user,
          suppress_automatic_dispatch: !automatic_response,
          skip_content_validation: message_content.blank? && files.present? && files.any? # Skip content validation if we have files but no content
        })
        message.attachments.attach(files) if files.present? && files.any?
        if audio_signed_id.present?
          begin
            message.audio_recording.attach(audio_signed_id)
            message.update!(audio_source: true)
          rescue ActiveSupport::MessageVerifier::InvalidSignature
            Rails.logger.warn "Invalid audio_signed_id for initial message in chat #{chat.id}"
          end
        end
        chat.send(:accept_opening_mention_dispatch, message) if automatic_response
      end
      chat
    end
  end

  def accept_opening_mention_dispatch(message)
    return if sole_resident
    return unless AgentRuntimeInteraction.live_activity_enabled?

    target_ids = mentioned_agent_ids(message.content.to_s)
    return if target_ids.empty?

    dispatch = MessageDispatch.accept!(message: message, target_agent_ids: target_ids)
    ActiveRecord.after_all_transactions_commit do
      MessageDispatchJob.perform_later(dispatch)
    rescue StandardError => e
      Rails.logger.warn "[Chat] opening dispatch #{dispatch.id} enqueue failed, wake will lapse: #{e.class}: #{e.message}"
    end
  end
  private :accept_opening_mention_dispatch

  def title_or_default
    title.presence || "New Conversation"
  end

  # Returns cached JSON representation, invalidated when chat is updated
  # (which happens automatically when messages are added via touch: true)
  def cached_json(as: nil)
    Rails.cache.fetch(json_cache_key(as: as)) do
      as.present? ? as_json(as: as) : as_json
    end
  end

  def cached_sidebar_json
    cached_json(as: :sidebar_json)
  end

  def self.cached_json_for(chats, as: nil)
    return [] if chats.blank?

    entries = chats.map { |chat| [ chat, chat.json_cache_key(as: as) ] }
    cached = Rails.cache.read_multi(*entries.map(&:last))
    missing = {}

    entries.each do |chat, key|
      next if cached.key?(key)

      missing[key] = as.present? ? chat.as_json(as: as) : chat.as_json
    end

    if missing.any?
      if Rails.cache.respond_to?(:write_multi)
        Rails.cache.write_multi(missing)
      else
        missing.each { |key, value| Rails.cache.write(key, value) }
      end
    end

    entries.map { |_, key| cached[key] || missing[key] }
  end

  # Run state must not be cached with chat content or touch/reorder the chat.
  def self.sidebar_json_for(chats)
    chats = chats.to_a
    working = AgentRuntimeInteraction.active
      .where(chat_id: chats.map(&:id))
      .where("execution_state IS NULL OR execution_state NOT IN (?)", AgentRuntimeInteraction::TERMINAL_STATES)
      .distinct.pluck(:chat_id, :agent_id).group_by(&:first)

    cached_json_for(chats, as: :sidebar_json).zip(chats).map do |json, chat|
      ids = (working[chat.id] || []).map { |_, id| Agent.encode_id(id) }
      json.merge("working_agent_ids" => ids)
    end
  end

  def json_cache_key(as: nil)
    "#{cache_key_with_version}/json/#{as || 'default'}/v4/#{visual_tag&.cache_key_with_version || 'untagged'}"
  end

  def updated_at_formatted
    updated_at.strftime("%b %d at %l:%M %p")
  end

  def updated_at_short
    updated_at.strftime("%b %d")
  end

  def message_count
    messages.kept.count
  end

  # Returns paginated messages for display
  # Uses cursor-based pagination with before_id for efficient loading of older messages
  # Returns the most recent N messages that are older than before_id, in ascending order for display
  def messages_page(before_id: nil, limit: 30)
    scope = messages.kept.includes(:user, :agent, :runtime_interaction).with_attached_attachments.with_attached_audio_recording
    scope = scope.where("messages.id < ?", Message.decode_id(before_id)) if before_id.present?
    # Use reorder to replace the association ordering,
    # get the most recent messages by ordering by ID DESC, limit, then reverse for display
    scope.reorder(id: :desc).limit(limit).reverse
  end

  # Worst-case input-token pressure across recent assistant turns. Cached on the row so the chats
  # sidebar can include it without N+1 queries; refreshed by Message after_save_commit.
  def recalculate_context_tokens!
    value = messages.kept.where(role: "assistant").reorder(created_at: :desc).limit(10).maximum(:input_tokens) || 0
    return if value == context_tokens
    update_columns(context_tokens: value, updated_at: Time.current)
  end

  # Lifetime billed input/output tokens for this chat.
  def cost_tokens
    {
      input:  messages.sum(:input_tokens),
      output: messages.sum(:output_tokens)
    }
  end

  # Lifetime reasoning tokens for this chat.
  def reasoning_tokens
    messages.sum(:thinking_tokens)
  end

  # Returns participants info for group chats (agents + unique humans)
  def participants_json
    return [] unless manual_responses?

    participants = []

    # Add agents with their icons and colours
    agents.each do |agent|
      participants << {
        type: "agent",
        id: agent.to_param,
        name: agent.name,
        icon: agent.icon,
        colour: agent.colour
      }
    end

    # Add unique human participants from messages
    messages.kept.unscope(:order).where.not(user_id: nil).distinct.pluck(:user_id).each do |user_id|
      user = User.find(user_id)
      participants << {
        type: "human",
        name: user.full_name.presence || user.email_address.split("@").first,
        avatar_url: user.avatar_url,
        colour: user.chat_colour
      }
    end

    participants
  end

  # Group chat functionality
  def group_chat?
    manual_responses?
  end

  # An ArgumentError, so the web still treats it as a refused trigger; the app
  # API tells it apart as a 409 (#94 B, step 4b-iii).
  class AlreadyResponding < ArgumentError; end

  def trigger_agent_response!(agent)
    raise ArgumentError, "Resident not in this conversation" unless agents.include?(agent)
    agent.require_conversation_runtime!
    raise ArgumentError, "This chat does not support manual responses" unless manual_responses?
    raise ArgumentError, "This conversation is archived or deleted" unless respondable?
    raise AlreadyResponding, "#{agent.name} is already responding" if agent_response_active?(agent)

    if AgentRuntimeInteraction.live_activity_enabled?
      AgentRuntimeInteraction.reserve!(agent: agent, chat: self, enqueue: true)
    else
      ManualAgentResponseJob.perform_later(self, agent)
    end
  end

  def trigger_all_agents_response!
    raise ArgumentError, "This chat does not support manual responses" unless manual_responses?
    raise ArgumentError, "No residents in this conversation" if agents.empty?
    raise ArgumentError, "This conversation is archived or deleted" unless respondable?

    # Get agent IDs in a consistent order
    ordered_agents = agents.order(:id).to_a
    unless ordered_agents.any?(&:eligible_for_conversation?)
      raise Agent::RuntimeAvailability::Unavailable.new("No available residents in this conversation", code: "no_available_agents")
    end
    active_agent = ordered_agents.find { |agent| agent.eligible_for_conversation? && agent_response_active?(agent) }
    raise AlreadyResponding, "#{active_agent.name} is already responding" if active_agent

    agent_ids = ordered_agents.map(&:id)

    # Queue the job that will process all agents in sequence
    AllAgentsResponseJob.perform_later(self, agent_ids)
  end

  # The residents a human message asks for, in mention order: eligible and not
  # already responding. Resolved once, when the message is accepted (#94 B,
  # step 4b-ii); an edit never re-resolves them.
  # The room's only resident, or nil when it has none or several.
  def sole_resident
    residents = agents.limit(2).to_a
    residents.one? ? residents.first : nil
  end

  def mentioned_agent_ids(content)
    return [] if content.blank? || !manual_responses?

    agents.select { |agent|
      content.match?(/@#{Regexp.escape(agent.name)}\b/i)
    }.reject { |agent|
      !agent.eligible_for_conversation? || agent_response_active?(agent)
    }.sort_by { |agent|
      content.index(/@#{Regexp.escape(agent.name)}\b/i)
    }.map(&:id)
  end

  # The conversation's recent runtime interactions, oldest first, with
  # in-flight live runs reconciled first so a lost run doesn't show as
  # working. Shared by the web activity panel and the app API.
  def activity_timeline(limit: 20)
    scope = agent_runtime_interactions.includes(:agent)
    active = scope.where(finished_at: nil).where.not(run_id: nil).to_a
    active.each(&:reconcile_activity!)
    (active + scope.recent.limit(limit).to_a).uniq
      .sort_by { |interaction| [ interaction.created_at, interaction.id ] }
  end

  def agent_response_active?(agent)
    agent_runtime_interactions.where(agent: agent, finished_at: nil).each(&:reconcile_activity!)
    agent_runtime_interactions
      .where(agent: agent, trigger_kind: "conversation", finished_at: nil)
      .active
      .exists?
  end

  # Queue moderation for all unmoderated messages with content
  def queue_moderation_for_all_messages
    unmoderated = messages.where(moderated_at: nil).where.not(content: [ nil, "" ])
    unmoderated.find_each { |message| ModerateMessageJob.perform_later(message) }
    unmoderated.count
  end

  private

  def visual_tag_belongs_to_account
    if visual_tag && visual_tag.account_id != account_id
      errors.add(:visual_tag, "must belong to this account")
    end
  end

  def configure_defaults
    unless ai_model_id.present? || model_id_string.present?
      self.model_id = "openrouter/auto"
    end
  end

  def model_must_be_present
    if ai_model.blank? && model_id_string.blank?
      errors.add(:model_id, "can't be blank")
    end
  end

end
