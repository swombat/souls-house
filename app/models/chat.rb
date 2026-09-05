class Chat < ApplicationRecord

  include Discard::Model
  include Broadcastable
  include ObfuscatesId
  include SyncAuthorizable
  include JsonAttributes
  include Chat::AgentOnly
  include Chat::Archivable
  include Chat::Forkable
  include Chat::Initiable

  belongs_to :ai_model, optional: true
  has_many :messages, -> { order(created_at: :asc) }, dependent: :destroy
  include Chat::ModelSelection
  include Chat::Summarizable

  belongs_to :account
  belongs_to :active_whiteboard, class_name: "Whiteboard", optional: true

  has_many :chat_agents, dependent: :destroy
  has_many :agents, through: :chat_agents
  has_many :agent_runtime_interactions, dependent: :nullify
  validates :agents, length: { minimum: 1, message: "must include at least one agent" }, if: :manual_responses?

  json_attributes :title_or_default, :model_id, :model_label, :ai_model_name, :updated_at_formatted,
                  :updated_at_short, :message_count, :context_tokens, :cost_tokens, :reasoning_tokens, :web_access, :manual_responses,
                  :participants_json, :archived_at, :discarded_at, :archived, :discarded, :respondable, :agent_only, :summary do |hash, options|
    # For sidebar format, only include attributes used by the chat list UI.
    if options&.dig(:as) == :sidebar_json
      hash.slice!(
        "id",
        "title",
        "title_or_default",
        "updated_at",
        "updated_at_short",
        "message_count",
        "context_tokens",
        "manual_responses",
        "participants_json",
        "archived",
        "discarded",
        "agent_only"
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

  scope :latest, -> { order(updated_at: :desc) }

  # Create chat with optional initial message
  def self.create_with_message!(attributes, message_content: nil, user: nil, files: nil, agent_ids: nil)
    transaction do
      chat = new(attributes)
      chat.agent_ids = agent_ids if agent_ids.present?
      chat.save!

      if message_content.present? || (files.present? && files.any?)
        message = chat.messages.create!({
          content: message_content || "",
          role: "user",
          user: user,
          skip_content_validation: message_content.blank? && files.present? && files.any? # Skip content validation if we have files but no content
        })
        message.attachments.attach(files) if files.present? && files.any?
      end
      chat
    end
  end

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

  def json_cache_key(as: nil)
    return cache_key_with_version unless as.present?

    "#{cache_key_with_version}/json/#{as}"
  end

  def updated_at_formatted
    updated_at.strftime("%b %d at %l:%M %p")
  end

  def updated_at_short
    updated_at.strftime("%b %d")
  end

  def message_count
    messages.count
  end

  # Returns paginated messages for display
  # Uses cursor-based pagination with before_id for efficient loading of older messages
  # Returns the most recent N messages that are older than before_id, in ascending order for display
  def messages_page(before_id: nil, limit: 30)
    scope = messages.includes(:user, :agent).with_attached_attachments.with_attached_audio_recording
    scope = scope.where("messages.id < ?", Message.decode_id(before_id)) if before_id.present?
    # Use reorder to replace the association ordering,
    # get the most recent messages by ordering by ID DESC, limit, then reverse for display
    scope.reorder(id: :desc).limit(limit).reverse
  end

  # Worst-case input-token pressure across recent assistant turns. Cached on the row so the chats
  # sidebar can include it without N+1 queries; refreshed by Message after_save_commit.
  def recalculate_context_tokens!
    value = messages.where(role: "assistant").reorder(created_at: :desc).limit(10).maximum(:input_tokens) || 0
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
        name: agent.name,
        icon: agent.icon,
        colour: agent.colour
      }
    end

    # Add unique human participants from messages
    messages.unscope(:order).where.not(user_id: nil).distinct.pluck(:user_id).each do |user_id|
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

  def trigger_agent_response!(agent)
    raise ArgumentError, "Agent not in this conversation" unless agents.include?(agent)
    agent.require_conversation_runtime!
    raise ArgumentError, "This chat does not support manual responses" unless manual_responses?
    raise ArgumentError, "This conversation is archived or deleted" unless respondable?
    raise ArgumentError, "#{agent.name} is already responding" if agent_response_active?(agent)

    ManualAgentResponseJob.perform_later(self, agent)
  end

  def trigger_all_agents_response!
    raise ArgumentError, "This chat does not support manual responses" unless manual_responses?
    raise ArgumentError, "No agents in this conversation" if agents.empty?
    raise ArgumentError, "This conversation is archived or deleted" unless respondable?

    # Get agent IDs in a consistent order
    ordered_agents = agents.order(:id).to_a
    unless ordered_agents.any?(&:eligible_for_conversation?)
      raise Agent::RuntimeAvailability::Unavailable.new("No available agents in this conversation", code: "no_available_agents")
    end
    active_agent = ordered_agents.find { |agent| agent.eligible_for_conversation? && agent_response_active?(agent) }
    raise ArgumentError, "#{active_agent.name} is already responding" if active_agent

    agent_ids = ordered_agents.map(&:id)

    # Queue the job that will process all agents in sequence
    AllAgentsResponseJob.perform_later(self, agent_ids)
  end

  def trigger_mentioned_agents!(content)
    return if content.blank? || !manual_responses?

    mentioned_ids = agents.select { |agent|
      content.match?(/@#{Regexp.escape(agent.name)}\b/i)
    }.reject { |agent|
      !agent.eligible_for_conversation? || agent_response_active?(agent)
    }.sort_by { |agent|
      content.index(/@#{Regexp.escape(agent.name)}\b/i)
    }.map(&:id)

    AllAgentsResponseJob.perform_later(self, mentioned_ids) if mentioned_ids.any?
  end

  def agent_response_active?(agent)
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
