class AgentRuntimeAttempt < ApplicationRecord

  belongs_to :agent_runtime_interaction
  has_many :agent_runtime_events, dependent: :delete_all

end
