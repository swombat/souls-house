# When the site's speech-engine (or voice-mode) scope changes, every open
# conversation must reload its voice_mode prop, so a panel or Listen player
# still speaking with the old engine stops (Mira, jEDyze, review of #790).
#
# The marker goes to each account's own stream, the one an open chat already
# subscribes to for voice_mode. It carries no setting values: the page asks
# the server for its voice_mode again and gets only what that account may see.
# Setting:all stays a site-admin stream.
class VoiceModeInvalidationJob < ApplicationJob

  MARKER = { action: "refresh", prop: "voice_mode" }.freeze

  def perform
    Account.select(:id).find_each do |account|
      ActionCable.server.broadcast("Account:#{account.obfuscated_id}", MARKER)
    end
  end

end
