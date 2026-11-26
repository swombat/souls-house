# A conversation or rhythm pinned to a model that has since left the
# resident's list moves forward to that model's successor, when the list
# carries one (Daniel, ewWyMe, 26 Nov: "if a resident in a thread is set to
# say Sol 6.1, but they don't have access to Sol 6.1 anymore, but they have
# access to Sol 6.2, it should automatically fail forwards").
#
# The rules, from the build thread (JlRlKe) with Mira's review:
# - Lineage is written down here, never guessed at dispatch. A model with no
#   entry, or a line whose newer models are all off the list, keeps its pin
#   and is refused visibly as before (ModelSelection, #1118).
# - Forward only, within one line, and only to a model the resident may
#   select (its default counts).
# - Only the pin that has stopped working moves: this conversation's seat,
#   and the rhythm seat that seeds it. A room's model default is shared by
#   everyone who joins that room and is never rewritten here; the seat it
#   seeded is the resident's own and moves like any other.
# - Each write is conditional on the row still holding the model that was
#   read, so a person's re-pick made meanwhile wins, and two wakes racing
#   produce one move and one house line.
# - Anything other than "not on the list" (a provider connection, an
#   outage, a rate limit) never moves a pin.
module Agents
  class ModelSuccession

    # model id => the model that replaced it in the same line. Add the
    # predecessor's entry when a model is added (the model-mapping rhythm,
    # jYxaJK, does this). Entries may name ids that have left the catalogue,
    # so old pins still resolve.
    SUCCESSORS = {
      # Anthropic
      "anthropic/claude-opus-4.1" => "anthropic/claude-opus-4.5",
      "anthropic/claude-opus-4.5" => "anthropic/claude-opus-4.6",
      "anthropic/claude-opus-4.6" => "anthropic/claude-opus-4.7",
      "anthropic/claude-opus-4.7" => "anthropic/claude-opus-4.8",
      "anthropic/claude-opus-4.8" => "anthropic/claude-opus-5",
      "anthropic/claude-opus-5" => "anthropic/claude-opus-5.5",
      "anthropic/claude-fable-5" => "anthropic/claude-fable-5.1",
      "anthropic/claude-fable-5.1" => "anthropic/claude-fable-5.2",
      "anthropic/claude-sonnet-4.5" => "anthropic/claude-sonnet-4.6",
      "anthropic/claude-sonnet-4.6" => "anthropic/claude-sonnet-5",
      "anthropic/claude-haiku-4.5" => "anthropic/claude-haiku-5.5",
      # OpenAI: GPT-6 lines by name; the unnamed GPT-5 line stops at 5.5,
      # since 5.6 split into Sol, Terra and Luna and none is its single heir.
      "openai/gpt-5.6-sol" => "openai/gpt-6-sol",
      "openai/gpt-6-sol" => "openai/gpt-6.1-sol",
      "openai/gpt-6.1-sol" => "openai/gpt-6.2-sol",
      "openai/gpt-6-astra" => "openai/gpt-6.2-astra",
      "openai/gpt-5.6-terra" => "openai/gpt-6.1-terra",
      "openai/gpt-5.6-luna" => "openai/gpt-6-luna",
      "openai/gpt-5" => "openai/gpt-5.1",
      "openai/gpt-5.1" => "openai/gpt-5.2",
      "openai/gpt-5.2" => "openai/gpt-5.4",
      "openai/gpt-5.4" => "openai/gpt-5.5",
      "openai/gpt-5-mini" => "openai/gpt-5.4-mini",
      "openai/gpt-5-nano" => "openai/gpt-5.4-nano",
      # Google. Gemini 4's codenames (Argon, Carbon, Hydrogen, Neon) have no
      # recorded order yet, so pins on them block rather than guess.
      "google/gemini-2.5-pro" => "google/gemini-3.1-pro-preview",
      "google/gemini-2.5-flash" => "google/gemini-3-flash-preview",
      "google/gemini-3-flash-preview" => "google/gemini-3.5-flash",
      "google/gemini-3.5-flash" => "google/gemini-3.6-flash",
      "google/gemini-3.6-flash" => "google/gemini-3.7-flash",
      "google/gemini-3.7-flash" => "google/gemini-3.8-flash",
      "google/gemini-2.5-flash-lite" => "google/gemini-3.1-flash-lite",
      "google/gemini-3.1-flash-lite" => "google/gemini-3.5-flash-lite",
      # xAI
      "x-ai/grok-4.3" => "x-ai/grok-4.5",
      "x-ai/grok-4.5" => "x-ai/grok-4.6",
      "x-ai/grok-4.6" => "x-ai/grok-4.7"
    }.freeze

    Move = Data.define(:from_model_id, :to_model_id, :rhythm)

    # The newest model reached by following the line forward from model_id
    # that the resident may select, or nil. Pure: reads, never writes.
    def self.successor_for(agent, model_id)
      seen = Set[model_id.to_s]
      current = model_id.to_s
      while (following = SUCCESSORS[current]) && seen.add?(following)
        return following if Agent.model_family(following) == Agent.model_family(model_id) &&
          agent.model_selection_problem(following).nil?

        current = following
      end
      nil
    end

    # Call when a turn starts, before its model is resolved. Returns the Move
    # it committed, or nil when nothing moved.
    def self.repair!(agent, chat:)
      new(agent, chat).repair!
    end

    def initialize(agent, chat)
      @agent = agent
      @chat = chat
    end

    def repair!
      return unless @chat&.persisted?

      seat = ChatAgent.find_by(chat_id: @chat.id, agent_id: @agent.id)
      pinned = seat&.model_id.presence
      return unless pinned && off_list?(pinned)

      successor = self.class.successor_for(@agent, pinned)
      return unless successor

      ChatAgent.transaction do
        moved = ChatAgent.where(id: seat.id, model_id: pinned).update_all(model_id: successor)
        next unless moved == 1

        rhythm = repair_rhythm_seat(pinned, successor)
        ConversationModelEvent.moved_forward!(seat: seat.reload, from_model_id: pinned, to_model_id: successor, rhythm: rhythm)
        Move.new(from_model_id: pinned, to_model_id: successor, rhythm: rhythm)
      end
    end

    private

    def off_list?(model_id)
      model_id != @agent.model_id && !@agent.switchable_model_ids.include?(model_id)
    end

    # A rhythm's own seat is the authority its next occurrence copies from
    # (Rhythm#apply_seat_models); moving only this conversation's copy would
    # break again at the next dispatch. Returns the rhythm when it moved.
    def repair_rhythm_seat(pinned, successor)
      rhythm_id = RhythmOccurrence.where(chat_id: @chat.id).pick(:rhythm_id)
      return unless rhythm_id

      moved = RhythmAgent.where(rhythm_id: rhythm_id, agent_id: @agent.id, model_id: pinned)
        .update_all(model_id: successor, updated_at: Time.current)
      Rhythm.find_by(id: rhythm_id) if moved == 1
    end

  end
end
