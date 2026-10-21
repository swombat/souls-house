class ChatAgent < ApplicationRecord

  include RhythmListingActivity

  SUMMARY_COOLDOWN = 5.minutes

  belongs_to :chat
  belongs_to :agent
  has_one :agent_bookmark, dependent: :destroy

  validates :agent_id, uniqueness: { scope: :chat_id }
  validate :agent_takes_part_in_account, on: :create
  # A new seat starts on the room's model for this resident, if it has one.
  before_create :seed_model_from_room

  # A second seat ends a quiet rhythm run's solitude (Chat::QuietRhythmRun).
  after_create_commit -> { chat.announce_listing_change }
  # Leaving one resident can make a rhythm run quiet again: off the list, so
  # its room stops spinning for it.
  after_destroy_commit -> { chat.refresh_room_activity if chat.rhythm_run? }

  scope :closed_for_initiation, -> { where.not(closed_for_initiation_at: nil) }
  scope :open_for_initiation, -> { where(closed_for_initiation_at: nil) }

  def closed_for_initiation? = closed_for_initiation_at?

  def close_for_initiation!
    update!(closed_for_initiation_at: Time.current)
  end

  def reopen_for_initiation!
    update!(closed_for_initiation_at: nil)
  end

  def summary_stale?
    agent_summary_generated_at.nil? || agent_summary_generated_at < SUMMARY_COOLDOWN.ago
  end

  # Select the model this resident runs on in this conversation. nil (or
  # "default") follows the resident's default. Applies from the next turn; a
  # running turn keeps the model it started with. Returns false when nothing
  # changed. Raises ModelNotAllowed for a model the resident may not use.
  class ModelNotAllowed < StandardError; end

  def select_model!(requested, by:)
    requested = requested.to_s.strip
    requested = nil if requested.blank? || requested == "default"
    if requested && (problem = agent.model_selection_problem(requested))
      raise ModelNotAllowed, "#{Agent.label_for_model(requested)} #{problem}"
    end

    with_lock do
      previous = model_id
      next false if previous == requested

      update!(model_id: requested)
      ConversationModelEvent.changed!(seat: self, from_model_id: previous, to_model_id: requested, by: by)
      true
    end
  end

  def clear_borrowed_context!
    update_columns(borrowed_context_json: nil) if borrowed_context_json.present?
  end

  private

  def seed_model_from_room
    return if model_id.present? || chat.nil? || agent.nil?
    return unless agent.account_id == chat.account_id

    self.model_id = RoomModelDefault.model_for(account_id: chat.account_id, room_id: chat.room_id, agent: agent)
  end

  # A seat needs a resident hosted in the room's account, or a guest there.
  # The guest check share-locks the membership row until this seat commits;
  # GuestMembership#close_seats locks the same row for update first, so a
  # departure either waits for this seat and closes it, or wins and this
  # check fails. Neither order can leave a seat without a membership.
  def agent_takes_part_in_account
    return unless chat && agent
    return if agent.account_id == chat.account_id
    return if GuestMembership.where(account_id: chat.account_id, agent_id: agent.id).lock("FOR SHARE").exists?

    errors.add(:agent, "is not a resident or guest of this account")
  end

end
