class AiModel < ApplicationRecord

  has_many :chats, foreign_key: :ai_model_id

  validates :model_id, presence: true, uniqueness: { scope: :provider }
  validates :provider, :name, presence: true

end
