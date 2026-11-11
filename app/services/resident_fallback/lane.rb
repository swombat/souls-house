# A resident in one conversation can run on two Chaos sessions (#690): its
# subscription lane (the session it always had) and its paid-fallback lane.
# Each lane is its own session_id, so each keeps its own Chaos history and
# its own transcript cursor; the fallback lane's tool history never crosses
# to the subscription lane, only what it said in the room does.
#
# A fresh start owed in the conversation (a safeguard roll, a requested
# reset) must reach both lanes. ChatAgent#runtime_freshness_generation is
# that shared fact: both lanes send it as runtime_session_generation, and the
# runtime rolls a session whose sidecar recorded an older one, so a lane
# that missed a roll starts fresh on its next turn and a session from before
# a reset is never resumed.
module ResidentFallback
  module Lane

    SUFFIX = "-fallback".freeze

    module_function

    def session_id(agent, chat, fallback:)
      base = "#{agent.uuid}-#{chat.id}"
      fallback ? "#{base}#{SUFFIX}" : base
    end

    def fallback_session?(session_id) = session_id.to_s.end_with?(SUFFIX)

    def freshness_generation(agent, chat)
      ChatAgent.where(agent_id: agent.id, chat_id: chat.id).pick(:runtime_freshness_generation).to_i
    end

  end
end
