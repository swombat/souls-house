module RepositoryWatches
  # Who may arm a watch, and whether a room may still receive one when it
  # fires. Both return nil when allowed, otherwise [http_status, reason].
  module Authority

    module_function

    def arm_refusal(repository:, chat:, agent: nil, user: nil)
      return [ :not_found, "Repository not found" ] if repository.nil? || repository.removed?
      return [ :not_found, "Conversation not found" ] if chat.nil?

      if agent
        return [ :forbidden, "#{agent.name} has no grant on the GitHub connection for #{repository.full_name}" ] unless granted?(agent, repository)
        return [ :forbidden, "#{agent.name} is not in that conversation" ] unless chat.agents.exists?(agent.id)
      elsif user
        return [ :forbidden, "Not a member of that conversation's account" ] unless member?(user, chat.account_id)
      else
        return [ :forbidden, "Nobody to arm the watch" ]
      end

      room_refusal(repository, chat)
    end

    # Checked again when a watch fires or expires, so later changes to
    # grants, seats, membership or the room are honoured.
    def fire_refusal(watch)
      repository = watch.watched_repository
      return "repository disconnected" if repository.removed?
      return "GitHub connection not connected" unless repository.service_connection.status == "connected"

      if watch.created_by_agent_id
        agent = watch.created_by_agent
        return "the arming resident no longer exists" unless agent
        return "#{agent.name} no longer holds a grant on the GitHub connection" unless granted?(agent, repository)
        return "#{agent.name} is no longer in the conversation" unless watch.chat.agents.exists?(agent.id)
      else
        user = watch.created_by_user
        return "the person who armed it no longer has access" unless user && member?(user, watch.chat.account_id)
      end

      room_refusal(repository, watch.chat)&.last
    end

    # The room's readers must be allowed to receive the repository's
    # information. v1: the room is in the account that connected the
    # repository, and has no resident from another account in it.
    def room_refusal(repository, chat)
      return [ :unprocessable_entity, "The conversation is archived or deleted" ] unless chat.respondable?
      unless chat.account_id == repository.account_id
        return [ :unprocessable_entity, "The conversation must be in the account that connected #{repository.full_name}" ]
      end
      if chat.agents.where.not(account_id: chat.account_id).exists?
        return [ :unprocessable_entity, "The conversation has a guest resident from another account, so it cannot receive #{repository.full_name}'s results" ]
      end

      nil
    end

    def granted?(agent, repository)
      AgentServiceAccess.enabled.exists?(agent_id: agent.id, service_connection_id: repository.service_connection_id)
    end

    def member?(user, account_id)
      user.confirmed_accounts.exists?(account_id)
    end

  end
end
