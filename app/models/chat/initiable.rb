module Chat::Initiable

  extend ActiveSupport::Concern

  included do
    belongs_to :initiated_by_agent, class_name: "Agent", optional: true

    scope :initiated, -> { where.not(initiated_by_agent_id: nil) }
    scope :awaiting_human_response, -> {
      initiated.where.not(
        id: Message.where(role: "user").where.not(user_id: nil).select(:chat_id)
      )
    }
  end

  class_methods do
    def initiate_by_agent!(agent, topic:, message:, reason: nil, invite_agent_ids: [])
      agent.require_conversation_runtime!
      invited_agents = resolve_invited_agents(agent.account, invite_agent_ids)

      transaction do
        chat = agent.account.chats.new(
          title: topic,
          manual_responses: true,
          model_id: agent.model_id,
          initiated_by_agent: agent,
          initiation_reason: reason
        )
        chat.agent_ids = [ agent.id ] + invited_agents.map(&:id)
        chat.save!
        chat.messages.create!(role: "assistant", agent: agent, content: message)
        chat
      end.tap do |chat|
        agent.notify_subscribers!(chat.messages.last, chat)
        invited_agents.each_with_index do |invited_agent, index|
          delay = (index + 1).minutes
          ManualAgentResponseJob.set(wait: delay).perform_later(chat, invited_agent)
        end
      end
    end

    def resolve_invited_agents(account, obfuscated_ids)
      return [] if obfuscated_ids.blank?
      real_ids = obfuscated_ids.filter_map { |obfuscated_id| Agent.decode_id(obfuscated_id) }
      account.agents.eligible_for_conversation.where(id: real_ids).to_a
    end
  end

end
