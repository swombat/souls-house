# Retired inline execution. Compatibility shell until old queue entries drain.
class AgentInitiationDecisionJob < ApplicationJob

  def perform(*)
  end

end
