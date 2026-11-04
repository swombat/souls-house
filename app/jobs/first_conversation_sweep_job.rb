# Re-offers first conversations a lost job left behind: a birth whose first
# wake settled but whose conversation was never opened, a greeting still owed
# after its chat was saved, and a reserved greeting run nobody dispatched or
# settled. New greetings are offered only for births from the last day with a
# recorded creator (born after the feature).
class FirstConversationSweepJob < ApplicationJob

  queue_as :default

  # Both jobs decide under the agent's lock, so offering one the after-commit
  # path already enqueued does nothing twice.
  def perform(now: Time.current)
    recent = Agent.where.not(created_by_user_id: nil)
      .where(birth_committed_at: (now - Agents::FirstConversation::GIVE_UP_AFTER)..)

    recent.where(first_conversation_greeting: "owed").find_each do |agent|
      FirstConversationWakeJob.perform_later(agent.id)
    end
    # Reserved and not yet settled: a worker may have died between reserving
    # the run and dispatching it, or after the run ended. Settled whatever
    # its age, so a reservation is never left hanging.
    Agent.where(first_conversation_greeting: "sent").find_each do |agent|
      FirstConversationWakeJob.perform_later(agent.id)
    end
    recent.where(first_conversation_chat_id: nil).find_each do |agent|
      FirstConversationJob.perform_later(agent.id) if Agents::FirstConversation.trigger?(agent)
    end
    # Owed past the window: dropped, not chased. (A reserved one settles
    # through its run, which lapses at its own deadline.)
    Agent.where(first_conversation_greeting: "owed")
      .where(birth_committed_at: ...(now - Agents::FirstConversation::GIVE_UP_AFTER))
      .update_all(first_conversation_greeting: "skipped")
  end

end
