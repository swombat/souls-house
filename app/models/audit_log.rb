class AuditLog < ApplicationRecord

  include ObfuscatesId
  include SyncAuthorizable
  include Broadcastable

  belongs_to :user, optional: true
  belongs_to :account, optional: true
  belongs_to :auditable, polymorphic: true, optional: true

  validates :action, presence: true

  # Broadcast to admin collection for real-time updates
  broadcasts_to :all

  # Scopes for filtering (composable and chainable)
  scope :recent, -> { order(created_at: :desc) }
  scope :by_user, ->(user_id) { where(user_id: user_id) if user_id.present? }
  scope :by_account, ->(account_id) { where(account_id: account_id) if account_id.present? }
  scope :by_action, ->(action) { where(action: action) if action.present? }
  scope :by_type, ->(type) { where(auditable_type: type) if type.present? }
  scope :date_from, ->(date) { where("created_at >= ?", Date.parse(date.to_s)) if date.present? }
  scope :date_to, ->(date) { where("created_at <= ?", Date.parse(date.to_s).end_of_day) if date.present? }
  scope :for_refinement_session, ->(session_id) {
    where("action LIKE 'memory_refinement_%' AND data->>'session_id' = ?", session_id)
  }

  def self.available_actions
    distinct.pluck(:action).compact.sort
  end

  def self.available_types
    distinct.pluck(:auditable_type).compact.sort
  end

  # Audit data for a record's last save: its saved changes (minus
  # updated_at) merged over extra data, with filtered parameters masked.
  def self.data_with_changes(record, **extra_data)
    changes = record.saved_changes.except(:updated_at)
    ActiveSupport::ParameterFilter
      .new(Rails.application.config.filter_parameters)
      .filter(extra_data.merge(changes))
  end

  def display_action
    action.to_s.humanize
  end

  def actor_name
    user&.email_address || "System"
  end

  def target_name
    account&.name || "-"
  end

  def as_json(options = {})
    super(options).merge(
      "display_action" => display_action,
      "actor_name" => actor_name,
      "target_name" => target_name,
      "user" => user&.as_json
    )
  end

end
