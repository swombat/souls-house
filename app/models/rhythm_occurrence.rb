class RhythmOccurrence < ApplicationRecord

  belongs_to :rhythm, optional: true
  belongs_to :creator, class_name: "User", optional: true
  belongs_to :creator_agent, class_name: "Agent", optional: true
  belongs_to :chat
  belongs_to :message
  has_one :message_dispatch, through: :message

  validates :title, :rhythm_title, :opening, :creator_label, :scheduled_for, presence: true
  validates :request_key, presence: true, if: :manual?
  validates :request_key, length: { maximum: 128 }, allow_nil: true

  # The durable intent and occurrence have committed before the separate queue
  # database is touched. A lost enqueue remains visible as pending, then expired;
  # it does not start a fresh run from recovery or promise exactly-once output.
  after_create_commit :enqueue_dispatch

  private

  def enqueue_dispatch
    MessageDispatchJob.perform_later(message_dispatch) if message_dispatch
  rescue StandardError => error
    Rails.logger.warn "[RhythmOccurrence] #{id} dispatch enqueue failed: #{error.class}: #{error.message}"
  end

end
