# Retired inline execution. Compatibility shell until old queue entries drain.
class ConversationInitiationJob < ApplicationJob

  def perform(*)
  end

end
