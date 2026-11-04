# A new resident speaks first (Daniel, ekMMZJ, 26 Oct: "there's already a
# conversation in the chat instead of being just an empty chat"). Once its
# first-wake orientation has finished, or failed with the runtime healthy, the
# house opens one conversation in Main with the resident seated, posts
# nothing itself, and wakes the resident there once with an initiation reason.
# The resident may say hello, or leave the first word to the person.
#
# Once only. The decision whether a conversation already exists and the
# creation are made under the agent's row lock, and the chat id and
# "greeting owed" are committed together; the wake is enqueued after commit
# and the sweep (FirstConversationSweepJob) re-offers anything left owed, so a
# process dying in between doesn't lose the greeting. A greeting that reached
# the runtime is final, even if the resident chose to stay quiet.
#
# Billing hold, pause and readiness are checked here and again at wake time;
# none is inferred from the orientation timestamps.
module Agents
  class FirstConversation

    # A greeting still owed after this long is dropped, not chased.
    GIVE_UP_AFTER = 1.day
    # Reservations that never reached the runtime are retried this many times.
    MAX_ATTEMPTS = 3
    SYSTEM_TEST_TITLE_PREFIX = "system: agent test for".freeze

    def self.trigger?(agent)
      return false unless agent.born_hosted? && agent.created_by_user_id.present?
      return false if agent.first_conversation_chat_id.present?

      agent.orientation_completed_at.present? ||
        (agent.orientation_last_error_at.present? && agent.health_state == "healthy")
    end

    def self.offer_later(agent)
      FirstConversationJob.perform_later(agent.id) if trigger?(agent)
    end

    def self.open!(agent) = new(agent).open!
    def self.wake!(agent) = new(agent).wake!

    def initialize(agent)
      @agent = agent
    end

    # :opened, :existing, or a refusal symbol.
    def open!
      outcome = agent.with_lock do
        next :already_open if agent.first_conversation_chat_id.present?
        next :not_new_birth unless self.class.trigger?(agent)
        next refusal if refusal

        if (existing = person_started_chat)
          agent.update!(first_conversation_chat_id: existing.id, first_conversation_greeting: "skipped")
          next :existing
        end

        chat = agent.account.chats.create_with_message!(
          { title: "#{agent.name}'s first conversation", manual_responses: true, model_id: agent.model_id },
          agent_ids: [ agent.id ], automatic_response: false
        )
        agent.update!(first_conversation_chat_id: chat.id, first_conversation_greeting: "owed")
        :opened
      end
      FirstConversationWakeJob.perform_later(agent.id) if outcome == :opened
      outcome
    end

    # Drives the greeting one step: reserves a run for an owed greeting and
    # dispatches it, re-drives a reserved run nobody claimed, and settles one
    # that ended. Returns :spent (handed to the runtime client: final, even if
    # the resident stays quiet or the outcome is unknown), :pending, :unsent
    # (back to owed), :skipped, :not_owed, or a refusal (still owed).
    def wake!
      case agent.reload.first_conversation_greeting
      when "owed" then reserve_and_dispatch!
      when "sent" then resume!
      else :not_owed
      end
    end

    # Settles a reserved greeting from its run (see delivery): spent once it
    # reached the runtime, given back as owed if the run ended or lapsed
    # before that, otherwise still pending.
    def settle!
      agent.with_lock do
        next :not_owed unless agent.first_conversation_greeting == "sent"

        interaction = agent.first_conversation_interaction
        case delivery(interaction)
        when :reached
          agent.update!(first_conversation_greeting: "spent")
          :spent
        when :unsent
          interaction&.with_lock { interaction.finish_execution!("cancelled") if interaction.dispatch_claimed_at.nil? && !interaction.finished_at? }
          give_back!
          :unsent
        else
          :pending
        end
      end
    end

    # Whether the greeting's run reached the resident's runtime.
    # Synchronous runs: the request writes request_text just before invoking
    # the runtime client. Queued runs (ResidentTurn): the request is written
    # before the turn waits for capacity, so only admission counts; a turn
    # cancelled while still queued never reached the runtime. A turn admitted
    # and then withdrawn before submission is counted as reached: at most
    # once, never a second coaxing.
    def delivery(interaction)
      return :unsent if interaction.nil?

      if (turn = interaction.resident_turn)
        return :pending unless turn.finished_at?

        return turn.admitted_at? ? :reached : :unsent
      end
      return :reached if interaction.request_text.present? && !ResidentTurn.enabled?
      return :unsent if interaction.finished_at? || interaction.execution_deadline_at&.past?

      :pending
    end

    # Checked by ResidentTurn at admission and again before first submission
    # (dispatch_deliverable?): a queued greeting can wait for capacity long
    # after its claim, and a person may write meanwhile. Then the greeting is
    # withdrawn (the person's own wake is held and released when this run
    # ends) and the conversation is left alone. Lock order: turn, then agent.
    def self.turn_deliverable?(interaction)
      greeted = Agent.find_by(first_conversation_interaction_id: interaction.id) or return true

      new(greeted).send(:turn_deliverable?, interaction)
    end

    # Called from AgentRuntimeInteraction#claim_dispatch! for the greeting's
    # run. Under the chat then agent locks, yields (the actual claim) only if
    # the greeting is still owed to this run; otherwise records why not and
    # returns false.
    def claim(interaction)
      chat = interaction.chat or return false
      chat.with_lock do
        agent.with_lock do
          next false unless agent.first_conversation_greeting == "sent" && agent.first_conversation_interaction_id == interaction.id
          next false if person_first(chat)
          if refusal
            give_back!
            next false
          end
          yield
        end
      end
    end

    private

    def reserve_and_dispatch!
      chat = agent.first_conversation_chat
      return agent.with_lock { skip!(:skipped) } if chat.nil?

      interaction = nil
      outcome = chat.with_lock do
        agent.with_lock do
          next :not_owed unless agent.first_conversation_greeting == "owed"
          next skip!(:skipped) if agent.birth_committed_at < GIVE_UP_AFTER.ago || agent.first_conversation_attempts >= MAX_ATTEMPTS
          if (person = person_first(chat))
            next person
          end
          if (reason = refusal || dispatch_refusal(chat))
            next reason
          end

          interaction = AgentRuntimeInteraction.reserve!(agent: agent, chat: chat)
          agent.update!(first_conversation_greeting: "sent", first_conversation_interaction: interaction,
            first_conversation_attempts: agent.first_conversation_attempts + 1, first_conversation_woken_at: Time.current)
          :reserved
        rescue Chat::AlreadyResponding
          :busy
        rescue Agent::RuntimeAvailability::Unavailable
          :unavailable
        end
      end
      return outcome unless outcome == :reserved

      dispatch!(interaction)
    end

    # A run reserved but not yet claimed (its worker died, or the job was
    # lost) is driven again; the claim lets only one worker through.
    def resume!
      interaction = agent.first_conversation_interaction
      if interaction && interaction.dispatch_claimed_at.nil? && !interaction.finished_at? && interaction.execution_deadline_at&.future?
        return dispatch!(interaction)
      end

      settle!
    end

    def dispatch!(interaction)
      ExternalAgentResponseRequest.new(
        agent: agent, chat: interaction.chat, initiation_reason: reason_text, interaction: interaction
      ).call
      settle!
    rescue Agent::RuntimeAvailability::Unavailable
      settle!
    end

    # The person spoke first, here or in a conversation of their own: theirs
    # is the first word, and no greeting is owed.
    def person_first(chat)
      if (existing = person_started_chat(excluding: chat))
        agent.update!(first_conversation_chat_id: existing.id, first_conversation_greeting: "skipped")
        # Only under this chat's row lock (held by the caller): a message
        # being posted here waits on it and then fails on the missing chat,
        # rather than being deleted with it.
        chat.destroy! unless chat.messages.exists?
        return :skipped
      end
      return skip!(:skipped) if human_spoke?(chat)

      nil
    end

    # The run stays recorded on the agent, so every later gate (claim,
    # admission, submission) still recognises it as the greeting and refuses.
    def turn_deliverable?(interaction)
      agent.with_lock do
        next false unless agent.first_conversation_greeting == "sent"

        chat = interaction.chat or next false
        if (existing = person_started_chat(excluding: chat))
          agent.update!(first_conversation_chat_id: existing.id, first_conversation_greeting: "skipped")
          next false
        end
        next skip!(false) if human_spoke?(chat)

        true
      end
    end

    def skip!(outcome)
      agent.update!(first_conversation_greeting: "skipped")
      outcome
    end

    def give_back!
      exhausted = agent.first_conversation_attempts >= MAX_ATTEMPTS || agent.birth_committed_at < GIVE_UP_AFTER.ago
      agent.update!(first_conversation_greeting: exhausted ? "skipped" : "owed", first_conversation_interaction_id: nil,
        first_conversation_woken_at: nil)
    end

    # What the request would otherwise turn into a house notice in the room
    # without reaching the runtime: checked first so retries can't fill the
    # conversation with notices.
    def dispatch_refusal(chat)
      return :runtime_unreachable if agent.offline? || (agent.health_state == "unhealthy" && agent.consecutive_health_failures >= 6)
      return :model_unavailable unless Agents::ModelSelection.for(agent, chat: chat).ok?

      nil
    end

    public

    def reason_text
      person = creator
      name = ResidentFacingName.for(person) || "the person who looks after this account"
      relation = if person && person.id == agent.created_by_user_id
        "who created this resident"
      else
        "who owns the account this resident lives in"
      end
      orientation = if agent.orientation_completed_at.present?
        "Your first-wake orientation completed."
      else
        "Your first-wake orientation did not complete; the runtime is healthy."
      end
      <<~TEXT.squish
        The house opened this conversation for you and #{name}, #{relation}.
        You can say hello in your own way: perhaps something that caught your attention in your seed,
        or a question you'd like to ask. There is no prescribed greeting, and you're welcome to leave
        the first word to them. If they've already written, respond to what they said instead.
        (#{orientation})
      TEXT
    end

    # For the onboarding page: where the first conversation is, and whether
    # the resident has written in it. A reply is a message the resident
    # posted during a run, not a house notice (those carry no run) or a
    # progress line.
    def self.presentation(agent)
      chat = agent.first_conversation_chat or return nil
      replied = chat.messages.kept.without_safeguard_label
        .where(role: "assistant", agent_id: agent.id, progress_message: false)
        .where.not(runtime_interaction_id: nil).exists?
      { id: chat.to_param, has_reply: replied }
    end

    def creator
      agent.created_by_user || agent.account.owner
    end

    private

    attr_reader :agent


    def refusal
      return :inactive unless agent.active?
      return :paused if agent.paused?
      return :billing_held if agent.billing_held?
      return :runtime_not_ready unless agent.external? && agent.health_state == "healthy"

      nil
    end

    def person_started_chat(excluding: nil)
      scope = agent.chats.where("chats.title IS NULL OR chats.title NOT LIKE ?", "#{SYSTEM_TEST_TITLE_PREFIX}%")
        .where(id: Message.kept.where(role: "user").where.not(user_id: nil).select(:chat_id))
      scope = scope.where.not(id: excluding.id) if excluding
      scope.order("chats.created_at ASC, chats.id ASC").first
    end

    def human_spoke?(chat)
      chat.messages.kept.where(role: "user").where.not(user_id: nil).exists?
    end

  end
end
