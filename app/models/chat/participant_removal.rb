module Chat::ParticipantRemoval

  extend ActiveSupport::Concern

  def participant_removable_by?(agent, user)
    user.present? && (account.manageable_by?(user) ||
      (agent.account_id != account_id && agent.account.owned_by?(user)))
  end

  # Requests belong to a particular stay in the room, not just a resident.
  # Rejoining must not revive jobs, retries or handoffs from an earlier stay.
  def agent_seated_for_request?(agent_id, requested_at)
    seats = chat_agents.where(agent_id: agent_id)
    seats = seats.where("created_at <= ?", requested_at) if requested_at
    seats.exists?
  end

  # Returns false, changing nothing, when the seat is already gone (a
  # concurrent removal won the lock first).
  def remove_participant!(agent, by:)
    with_lock do
      raise Account::NotAuthorized unless participant_removable_by?(agent, by)

      seat = chat_agents.find_by(agent: agent)
      next false unless seat
      raise Chat::AlreadyResponding, "#{agent.name} is already responding; try again when they are idle" if agent_response_active?(agent)

      # reserve! holds this same chat lock. Either it wins and removal refuses,
      # or removal wins and that request can no longer reserve this seat.
      seat.destroy!
      PendingWake.open.where(chat: self, agent: agent).find_each { |wake| wake.drop!("not_in_room") }
      MessageHandoff.where(chat: self, recipient_agent: agent).open_requests.find_each do |handoff|
        handoff.update!(status: "blocked", reason: "not_in_room")
      end
      messages.create!(role: "user", content: "[System Notice] #{agent.name} has left the conversation.")
      yield if block_given?
      true
    end
  end

end
