class Mnemodyne::Vault < Mnemodyne::Record

  belongs_to :agent
  has_many :nodes, dependent: :restrict_with_error, inverse_of: :vault
  has_many :edges, dependent: :restrict_with_error, inverse_of: :vault
  has_many :operations, dependent: :restrict_with_error, inverse_of: :vault
  has_many :uses, dependent: :restrict_with_error, inverse_of: :vault

  validates :decay_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :charge_decay_rate, :charge_decay_floor, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }

  validate :owner_cannot_change, on: :update

  validates :agent_id, uniqueness: true
  after_update_commit :reembed_after_resume, if: -> { saved_change_to_suspended_at? && !suspended_at? }
  after_create_commit :schedule_first_checkpoint

  private

  def schedule_first_checkpoint
    if Agents::Config.backups_enabled?
      Mnemodyne::FirstCheckpointJob.set(wait_until: Mnemodyne::FirstCheckpointJob.next_attempt_at(agent)).perform_later(agent_id)
    end
  end

  def reembed_after_resume
    Mnemodyne::ReembedVaultJob.perform_later(id) if Mnemodyne::Embeddings.configured? && !erasure_requested_at?
  end

  def owner_cannot_change
    errors.add(:agent_id, "cannot change") if will_save_change_to_agent_id?
  end

end
