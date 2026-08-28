class SafeguardClassifierFailure < ApplicationRecord

  belongs_to :agent

  validates :provider, :model, :detector_version, :error_class, presence: true

end
