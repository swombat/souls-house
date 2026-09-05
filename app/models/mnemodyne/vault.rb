class Mnemodyne::Vault < Mnemodyne::Record

  belongs_to :agent
  has_many :nodes, dependent: :restrict_with_error, inverse_of: :vault
  has_many :edges, dependent: :restrict_with_error, inverse_of: :vault

  validate :owner_cannot_change, on: :update

  validates :agent_id, uniqueness: true

  private

  def owner_cannot_change
    errors.add(:agent_id, "cannot change") if will_save_change_to_agent_id?
  end

end
