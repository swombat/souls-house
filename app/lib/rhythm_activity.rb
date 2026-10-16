# Content-free invalidation for rhythm readers. Call after the producing
# transaction commits; account is an Account instance (or nil for no stream).
class RhythmActivity

  def self.broadcast_for(account)
    return unless account

    ActionCable.server.broadcast("RhythmActivity:#{account.obfuscated_id}", { action: "refresh" })
  rescue StandardError => error
    Rails.logger.warn("Rhythm activity refresh failed: #{error.class}")
  end

end
