class Mnemodyne::Node < Mnemodyne::Record

  INTEGRATION_STATES = %w[raw active integrated constitutional].freeze
  DISCLOSURES = %w[automatic never_automatic].freeze

  belongs_to :vault
  has_many :outgoing_edges, class_name: "Mnemodyne::Edge", foreign_key: :source_id, inverse_of: :source
  has_many :incoming_edges, class_name: "Mnemodyne::Edge", foreign_key: :target_id, inverse_of: :target

  validate :owner_cannot_change, on: :update

  validates :node_type, presence: true, length: { maximum: 100 }, format: { with: /\A[a-z][a-z0-9_]*\z/ }
  validates :content, presence: true, length: { maximum: 2_000 }
  validates :content, length: { maximum: 200 }, if: -> { node_type.in?(%w[need person]) }
  validates :description, length: { maximum: 4_000 }
  validates :content, uniqueness: { scope: [ :vault_id, :node_type ], case_sensitive: false },
    if: -> { node_type.in?(%w[need person]) }
  validates :charge, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :integration_state, inclusion: { in: INTEGRATION_STATES }
  validates :disclosure, inclusion: { in: DISCLOSURES }
  validates :embedding_profile, length: { maximum: 200 }
  validate :metadata_is_valid
  validate :source_uris_are_bounded_pointers

  before_destroy :prevent_constitutional_destruction

  scope :active, -> { where(is_dormant: false) }
  scope :automatically_disclosable, -> { active.where(disclosure: "automatic") }

  def baseline_activation
    metadata.fetch("baseline_activation", 0.0)
  end

  def decay_exempt?
    integration_state == "constitutional" || metadata["decay_exempt"] == true
  end

  private

  def prevent_constitutional_destruction
    throw(:abort) if integration_state == "constitutional"
  end

  def owner_cannot_change
    errors.add(:vault_id, "cannot change") if will_save_change_to_vault_id?
  end

  def metadata_is_valid
    unless metadata.is_a?(Hash)
      errors.add(:metadata, "must be an object")
      return
    end

    if metadata.key?("baseline_activation")
      activation = metadata["baseline_activation"]
      unless activation.is_a?(Numeric) && activation.finite? && activation.between?(0, 1)
        errors.add(:metadata, "baseline_activation must be a finite number in [0, 1]")
      end
    end

    if metadata.key?("decay_exempt") && ![ true, false ].include?(metadata["decay_exempt"])
      errors.add(:metadata, "decay_exempt must be a boolean")
    end
  end

  def source_uris_are_bounded_pointers
    unless source_uris.is_a?(Array) && source_uris.length <= 20 &&
        source_uris.all? { |uri| uri.is_a?(String) && uri.present? && uri.length <= 2_000 }
      errors.add(:source_uris, "must contain at most 20 nonblank pointers of at most 2000 characters")
    end
  end

end
