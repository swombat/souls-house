class Agent < ApplicationRecord

  include ActionView::Helpers::DateHelper
  include Broadcastable
  include ObfuscatesId
  include JsonAttributes
  include SyncAuthorizable
  include TelegramNotifiable
  include Agent::Heartbeat
  include Agent::Initiation
  include Agent::Memory
  include Agent::Predecessor
  include Agent::Tools

  belongs_to :account
  belongs_to :outbound_api_key, class_name: "ApiKey", optional: true
  has_many :chat_agents, dependent: :destroy
  has_many :agent_backup_snapshots, dependent: :destroy
  has_many :agent_runtime_interactions, dependent: :destroy
  has_many :metered_action_events, dependent: :destroy
  has_many :safeguard_detections, dependent: :destroy
  has_many :safeguard_classifier_failures, dependent: :destroy
  has_many :chats, through: :chat_agents
  has_many :agent_service_accesses, dependent: :destroy
  has_many :service_connections, through: :agent_service_accesses

  VALID_COLOURS = %w[
    slate gray zinc neutral stone
    red orange amber yellow lime green
    emerald teal cyan sky blue indigo
    violet purple fuchsia pink rose
  ].freeze

  VALID_ICONS = %w[
    Robot Brain Sparkle Lightning Star Heart Sun Moon Eye Globe
    Compass Rocket Atom Lightbulb Crown Shield Fire Target Trophy
    Flask Code Cube PuzzlePiece Cat Dog Bird Alien Ghost Detective
    Butterfly Flower Tree Leaf
  ].freeze
  REASONING_EFFORTS = %w[default none minimal low medium high xhigh max ultra].freeze
  PROVIDER_AUTH_MODES = %w[api_key oauth_account].freeze
  OAUTH_ACCOUNT_PROVIDERS = %w[anthropic gemini openai xai].freeze

  EXTERNALLY_MANAGED_ATTRIBUTES = %w[
    system_prompt reflection_prompt memory_reflection_prompt
    summary_prompt refinement_prompt refinement_threshold
    thinking_enabled thinking_budget enabled_tools
  ].freeze
  SENSITIVE_JSON_ATTRIBUTES = %i[
    github_deploy_key_priv outbound_api_token restic_password
    telegram_bot_token telegram_webhook_token trigger_bearer_token
  ].freeze
  LIST_JSON_ATTRIBUTES = %i[
    name model_id model_label active? paused? colour icon runtime health_state
  ].freeze

  validates :name, presence: true,
                   length: { maximum: 100 },
                   uniqueness: { scope: :account_id }
  validates :system_prompt, length: { maximum: 50_000 }
  validates :reflection_prompt, length: { maximum: 10_000 }
  validates :memory_reflection_prompt, length: { maximum: 10_000 }
  validates :summary_prompt, length: { maximum: 10_000 }
  validates :refinement_prompt, length: { maximum: 10_000 }
  validates :colour, inclusion: { in: VALID_COLOURS }, allow_nil: true
  validates :icon, inclusion: { in: VALID_ICONS }, allow_nil: true
  validates :thinking_budget,
             numericality: { greater_than_or_equal_to: 1000, less_than_or_equal_to: 50000 },
             allow_nil: true
  validates :reasoning_effort, inclusion: { in: REASONING_EFFORTS }
  validates :refinement_threshold,
             numericality: { greater_than: 0, less_than_or_equal_to: 1 },
             allow_nil: true
  validates :heartbeat_wakes_per_day,
            numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 48 }
  validates :runtime, inclusion: { in: %w[inline migrating provisioning external offline] }
  validates :health_state, inclusion: { in: %w[healthy unhealthy unknown] }
  validate :identity_fields_are_read_only_when_external
  after_update :create_model_change_notice, if: :saved_change_to_model_id?
  after_update_commit :enqueue_model_change_orientation, if: :saved_change_to_model_id?
  after_create_commit :apply_default_service_accesses
  broadcasts_to :account

  encrypts :trigger_bearer_token
  encrypts :github_deploy_key_priv
  encrypts :restic_password
  encrypts :outbound_api_token

  scope :active, -> { where(active: true) }
  scope :unpaused, -> { where(paused: false) }
  scope :by_name, -> { order(:name) }
  scope :externally_hosted, -> { where(runtime: %w[external offline]) }

  json_attributes :name, :system_prompt, :reflection_prompt, :memory_reflection_prompt,
                  :summary_prompt, :refinement_prompt, :refinement_threshold,
                  :model_id, :model_label, :enabled_tools, :active?, :paused?, :colour, :icon,
                  :memories_count, :memory_token_summary, :thinking_enabled, :thinking_budget,
                  :reasoning_effort,
                  :telegram_bot_username, :telegram_configured?,
                  :voiced?, :voice_id, :runtime, :endpoint_url, :last_announced_at,
                   :last_health_check_at, :health_state, :consecutive_health_failures,
                   :github_repo_url, :github_repo_owner, :github_repo_name,
                   :github_deploy_key_id, :container_name, :sandbox_host, :container_image,
                      :sandbox_last_error, :sandbox_last_error_at, :birth_committed_at,
                   :provisioning_started_at, :identity_seeded_at, :runtime_ready_at,
                   :orientation_requested_at, :orientation_completed_at,
                   :orientation_last_error, :orientation_last_error_at, :oriented_at,
                   :persistent_session?, :persistent_wake_session?, :scheduled_wakes_enabled?,
                       :heartbeat_wakes_per_day,
                  except: SENSITIVE_JSON_ATTRIBUTES do |hash, options|
    # Keep credentials out even if a caller supplies runtime serialization options
    # that would otherwise override the configured `except` list.
    hash.except!(*SENSITIVE_JSON_ATTRIBUTES.map(&:to_s))

    if options&.dig(:as) == :list
      hash.slice!("id", *LIST_JSON_ATTRIBUTES.map(&:to_s))
    end

    hash
  end

  def self.json_attrs_for(options = nil)
    return json_attrs unless options&.dig(:as) == :list

    LIST_JSON_ATTRIBUTES
  end

  def model_label
    Chat::MODELS.find { |m| m[:model_id] == model_id }&.dig(:label) || model_id
  end

  def uses_thinking?
    thinking_enabled? && Chat.supports_thinking?(model_id)
  end

  def voiced?
    voice_id.present?
  end

  def inline? = runtime == "inline"

  def migrating? = runtime == "migrating"

  def provisioning? = runtime == "provisioning"

  def external? = runtime == "external"

  def offline? = runtime == "offline"

  def externally_hosted?
    external? || offline?
  end

  def born_hosted?
    birth_committed_at.present?
  end

  def identity_owned_by_agent?
    born_hosted? || externally_hosted?
  end

  def provisioning_failed?
    provisioning? && sandbox_last_error.present?
  end

  def provider_auth_mode(provider)
    provider_auth_modes.to_h.fetch(provider.to_s, "api_key")
  end

  def use_provider_auth_mode!(provider, mode)
    mode = mode.to_s
    raise ArgumentError, "unsupported provider auth mode" unless PROVIDER_AUTH_MODES.include?(mode)

    update!(provider_auth_modes: provider_auth_modes.to_h.merge(provider.to_s => mode))
  end

  def provider_connection(provider)
    provider_connections.to_h.fetch(provider.to_s, {})
  end

  def record_provider_connection!(provider, attributes)
    safe_attributes = attributes.to_h.stringify_keys.slice("email", "plan", "status", "connected_at")
    update!(
      provider_connections: provider_connections.to_h.merge(provider.to_s => safe_attributes),
      provider_auth_modes: provider_auth_modes.to_h.merge(provider.to_s => "oauth_account")
    )
  end

  def clear_provider_connection!(provider)
    update!(
      provider_connections: provider_connections.to_h.except(provider.to_s),
      provider_auth_modes: provider_auth_modes.to_h.merge(provider.to_s => "api_key")
    )
  end

  def mark_provider_connection_status!(provider, status)
    connection = provider_connection(provider)
    return if connection.blank?

    update!(
      provider_connections: provider_connections.to_h.merge(
        provider.to_s => connection.merge("status" => status.to_s)
      )
    )
  end

  def soul_seed
    system_prompt
  end

  def other_conversation_summaries(exclude_chat_id:)
    chat_agents
      .joins(:chat)
      .where.not(chat_id: exclude_chat_id)
      .where.not(agent_summary: [ nil, "" ])
      .where("chats.updated_at > ?", 6.hours.ago)
      .merge(Chat.kept)
      .includes(:chat)
      .order("chats.updated_at DESC", "chats.id DESC")
      .limit(10)
  end

  private

  def apply_default_service_accesses
    account.service_connections.where(enabled_for_new_agents: true).find_each do |connection|
      agent_service_accesses.find_or_create_by!(service_connection: connection) do |access|
        access.enabled = true
        access.follows_default = true
        access.provisioning_status = "pending"
      end
    end
  end

  def create_model_change_notice
    return unless identity_owned_by_agent?

    from, to = saved_change_to_model_id
    account.notices.create!(
      scope: "account",
      notice_type: "model_changed",
      params: {
        agent_id: to_param,
        agent_name: name,
        from: from,
        to: to,
        changed_at: Time.current.utc.iso8601
      },
      created_by: Current.user,
      expires_at: 7.days.from_now
    )
  end

  def enqueue_model_change_orientation
    return unless identity_owned_by_agent?

    ModelChangeOrientationJob.perform_later(id, model_id)
  end

  def identity_fields_are_read_only_when_external
    return unless persisted? && identity_owned_by_agent?

    return unless EXTERNALLY_MANAGED_ATTRIBUTES.any? { |field| will_save_change_to_attribute?(field) }

    errors.add(:base, "Identity and runtime-managed fields are agent-owned and read-only in souls.house")
  end

end
