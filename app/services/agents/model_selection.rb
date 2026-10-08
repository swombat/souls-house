# The one place that decides which model a resident runs on for a trigger.
# Resolve it once, when execution starts, and use the result for everything that
# turn touches: the model sent to Chaos, the facts the resident is told, the
# interaction record and the reply's attribution. Changes made while a turn
# runs apply to the next turn, never to this one or its retries.
#
# A conversation seat may select a model from the resident's allowlist. With no
# selection, or outside a conversation, the resident's default applies. A
# selection that has stopped being valid is reported as a problem, never
# quietly replaced with the default: the person chose that model.
module Agents
  class ModelSelection

    attr_reader :agent, :chat, :model_id, :provider, :model, :reasoning_effort, :problem, :selected_by_conversation

    def self.for(agent, chat: nil)
      new(agent, chat: chat)
    end

    def initialize(agent, chat: nil)
      @agent = agent
      @chat = chat
      selected = seat&.model_id.presence
      @selected_by_conversation = selected.present? && selected != agent.model_id
      @model_id = selected || agent.model_id
      @problem = agent.model_selection_problem(@model_id) if @selected_by_conversation
      resolve! unless @problem
    end

    def ok? = problem.nil?

    def label = Agent.label_for_model(model_id)

    def default_model_id = agent.model_id

    def default_label = agent.model_label

    def seat
      return @seat if defined?(@seat)

      @seat = chat && ChatAgent.find_by(chat_id: chat.id, agent_id: agent.id)
    end

    # What the resident is told at the top of a conversation trigger, so it
    # never has to infer its own model.
    def prompt_section
      return unless agent.model_switching_available? || selected_by_conversation

      lines = [ "## Your model in this conversation", "" ]
      lines << "You are running on #{label} (`#{model}`) for this turn#{effort_clause}."
      lines << if selected_by_conversation
        "This conversation selected it; your default model is #{default_label}."
      else
        "This is your default model; this conversation has not selected another."
      end
      lines << "Models this conversation can select for you: #{agent.model_choices.map { |choice| choice[:label] }.join(', ')}."
      lines << switch_instructions
      lines << "A model change keeps your Chaos session: what came before is still in your context, written by whichever model was running then."
      lines.compact.join("\n")
    end

    def as_json(*)
      {
        model_id: model_id,
        label: label,
        default_model_id: default_model_id,
        default_label: default_label,
        selected_by_conversation: selected_by_conversation,
        # nil follows the default, whatever it becomes; a model id pins one.
        seat_model_id: seat&.model_id,
        reasoning_effort: reasoning_effort,
        problem: problem && "#{label} #{problem}",
        choices: agent.model_choices
      }
    end

    private

    def resolve!
      selection = Agents::Sandbox.chaos_selection_for(agent, model_id: model_id)
      @provider = selection.fetch(:provider)
      @model = selection.fetch(:model)
      @reasoning_effort = resolved_effort
      if selected_by_conversation && @provider != Agents::Sandbox.chaos_provider_for(agent)
        @problem = "would run through a different provider connection than #{default_label}"
      end
    rescue KeyError, ArgumentError => e
      raise unless selected_by_conversation

      @problem = "cannot be reached with this account's connections (#{e.message})"
    end

    # The resident's configured effort belongs to its default model. A model
    # selected for a conversation runs at that model's own profile default
    # (agreed in pJWRRj): low effort on Sol is not carried over to Astra.
    def resolved_effort
      return agent.reasoning_effort unless selected_by_conversation

      config = Chat.reasoning_effort_config(model_id)
      config ? config[:default].to_s : "default"
    end

    def effort_clause
      return "" if reasoning_effort.blank? || reasoning_effort == "default"

      ", reasoning effort #{reasoning_effort}"
    end

    def switch_instructions
      return unless chat

      if agent.resident_may_switch_model?
        "You may change it yourself: `soulshouse-model #{chat.to_param} <model_id>` (or `default`). It applies from your next turn in this conversation and does not start one."
      else
        "People in the conversation can change it from your button in the room; you cannot change it yourself."
      end
    end

  end
end
