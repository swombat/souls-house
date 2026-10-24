# A description of an accepted wake, not permission to perform work. Callers
# supply authenticated principals or an explicit internal scheduler source.
# Display labels, initiation reasons and transcript text are never evidence.
module WakeProvenance

  KINDS = %w[human peer scheduled unknown].freeze

  def self.for(user: nil, requester_agent: nil, message: nil)
    return [ "human" ] if message&.user || user
    return [ "peer" ] if message&.agent || requester_agent

    []
  end

end
