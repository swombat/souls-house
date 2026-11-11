# One logical turn that hopped to the paid fallback (#690): the subscription
# attempt the runtime refused before dispatch, and the paid attempt that
# answered instead. The room's label reads this dispatched record, never the
# resident's current settings.
class ResidentFallbackTurn < ApplicationRecord

  belongs_to :agent
  belongs_to :chat, optional: true
  belongs_to :primary_interaction, class_name: "AgentRuntimeInteraction", optional: true
  belongs_to :fallback_interaction, class_name: "AgentRuntimeInteraction", optional: true
  has_many :calls, class_name: "ResidentFallbackCall", dependent: :nullify

  validates :primary_provider, :primary_model, :fallback_model_id, :upstream_model, presence: true

end
