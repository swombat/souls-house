class Mnemodyne::Edge < Mnemodyne::Record

  belongs_to :vault
  belongs_to :source, class_name: "Mnemodyne::Node", inverse_of: :outgoing_edges
  belongs_to :target, class_name: "Mnemodyne::Node", inverse_of: :incoming_edges

  validate :owner_cannot_change, on: :update

  validates :edge_type, presence: true, length: { maximum: 100 }, format: { with: /\A[a-z][a-z0-9_]*\z/ }
  validates :weight, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :edge_type, uniqueness: { scope: [ :vault_id, :source_id, :target_id ] }
  validate :endpoints_belong_to_vault
  validate :no_self_loop
  validate :metadata_is_an_object

  private

  def owner_cannot_change
    errors.add(:vault_id, "cannot change") if will_save_change_to_vault_id?
  end

  def endpoints_belong_to_vault
    errors.add(:source, "must belong to this vault") if source && source.vault_id != vault_id
    errors.add(:target, "must belong to this vault") if target && target.vault_id != vault_id
  end

  def no_self_loop
    errors.add(:target, "must differ from source") if source_id.present? && source_id == target_id
  end

  def metadata_is_an_object
    errors.add(:metadata, "must be an object") unless metadata.is_a?(Hash)
  end

end
