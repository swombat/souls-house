class Mnemodyne::Vault < Mnemodyne::Record

  belongs_to :agent
  has_many :nodes, dependent: :restrict_with_error, inverse_of: :vault
  has_many :edges, dependent: :restrict_with_error, inverse_of: :vault
  has_many :operations, dependent: :restrict_with_error, inverse_of: :vault
  has_many :uses, dependent: :restrict_with_error, inverse_of: :vault

  validates :decay_rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }

  validate :owner_cannot_change, on: :update

  validates :agent_id, uniqueness: true

  private

  def owner_cannot_change
    errors.add(:agent_id, "cannot change") if will_save_change_to_agent_id?
  end

end
