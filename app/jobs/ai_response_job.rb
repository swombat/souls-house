# Retired inline execution. Compatibility shell until old queue entries drain.
class AiResponseJob < ApplicationJob

  def perform(*)
  end

end
