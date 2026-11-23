# Which residents are working in each of an account's rooms, for the spinners
# in the room switchers. Account-wide, not derived from the sidebar's chats,
# which are filtered to the selected room. The same run-state rule as the
# sidebar's avatar rings (AgentRuntimeInteraction.working).
#
#   { rooms: { "main" => [ { id:, name:, colour: }, ... ], "<room id>" => [...] },
#     all: [...] }
#
# Each list's residents are newest start first, once each however many runs
# they have there: the first is the spinner's colour.
class RoomActivity

  EMPTY = { rooms: {}, all: [] }.freeze

  def self.summary_for(account)
    return EMPTY unless account

    # Private conversations don't spin anyone's room (eKmnrJ): the totals
    # are account-wide, so they can't show who is working where in one.
    chats = account.chats.kept.listed.where(private: false)
    runs = AgentRuntimeInteraction.working.where(chat_id: chats.select(:id))
      .group(:chat_id, :agent_id)
      .pluck(
        :chat_id, :agent_id,
        Arel.sql("MAX(agent_runtime_interactions.started_at)"),
        Arel.sql("BOOL_AND(#{AgentRuntimeInteraction.waking_phase_sql})")
      )
    return EMPTY if runs.empty?

    room_of = Chat.where(id: runs.map(&:first).uniq).pluck(:id, :room_id).to_h
    agents = Agent.where(id: runs.map(&:second).uniq).index_by(&:id)

    latest = Hash.new { |hash, key| hash[key] = {} }
    waking_in = Hash.new { |hash, key| hash[key] = {} }
    everywhere = {}
    waking_everywhere = {}
    runs.each do |chat_id, agent_id, started_at, is_waking|
      room_id = room_of[chat_id]
      key = room_id ? Room.encode_id(room_id) : "main"
      latest[key][agent_id] = [ latest[key][agent_id], started_at ].compact.max
      waking_in[key][agent_id] = waking_in[key].fetch(agent_id, true) && is_waking
      everywhere[agent_id] = [ everywhere[agent_id], started_at ].compact.max
      waking_everywhere[agent_id] = waking_everywhere.fetch(agent_id, true) && is_waking
    end

    order = ->(starts, waking) {
      starts.sort_by { |agent_id, started_at| [ -started_at.to_f, agent_id ] }.filter_map do |agent_id, _|
        next unless (agent = agents[agent_id])
        entry = { id: agent.to_param, name: agent.name, colour: agent.colour }
        entry[:phase] = "waking" if waking[agent_id]
        entry
      end
    }
    { rooms: latest.to_h { |key, starts| [ key, order.(starts, waking_in[key]) ] }, all: order.(everywhere, waking_everywhere) }
  end

  def self.refresh_for(account)
    return unless account
    ActionCable.server.broadcast("RoomActivity:#{account.obfuscated_id}", { action: "refresh" })
  rescue StandardError => error
    Rails.logger.warn("Room activity refresh failed: #{error.class}")
  end

end
