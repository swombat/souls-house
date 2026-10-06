# The standing sub-agent permission a resident carries into every trigger when
# its owner has turned it on. Chaos's spawn_agent description says to delegate
# only when the user explicitly asks; this section is that explicit ask, made
# once by the owner instead of in every conversation.
class SubagentPolicyRenderer

  def self.section_for(agent)
    new(agent).section
  end

  def initialize(agent)
    @agent = agent
  end

  def section
    return unless @agent.subagents_enabled?

    <<~TEXT.strip
      ## Sub-agents: standing permission

      The people who run this resident's account have given you standing permission to use sub-agents (`spawn_agent`, `run_synopsis`) without being asked in the conversation. This setting is the explicit user authorisation those tools require. Delegate when a subtask is bounded and self-contained and can run in parallel with your own work, especially mechanical or well-specified work a cheaper model can do. Keep critical-path, tightly coupled or judgement-heavy work yourself, and review what helpers return before you rely on it.

      #{models_text}
    TEXT
  end

  private

  def own_provider
    Agents::Sandbox.chaos_provider_for(@agent)
  rescue KeyError
    nil
  end

  def models_text
    models = @agent.available_subagent_models
    if models.empty?
      return "No other models are allowed for sub-agents. Spawn them on your own model: omit `model` and `model_provider`."
    end

    lines = models.map do |entry|
      provider = entry[:provider] == own_provider ? "omit `model_provider` (your own provider)" : "`model_provider: #{entry[:provider]}`"
      "- #{entry[:label]}: `model: #{entry[:model]}`, #{provider} (#{entry[:provider_label]}, #{entry[:source]})"
    end
    <<~TEXT.strip
      Allowed sub-agent models. Use only these, or your own model (omit `model` and `model_provider`):
      #{lines.join("\n")}
      If spawn_agent rejects one of these names, it lists the names it accepts. Use the matching one, and do not substitute a model that is not on this list.
    TEXT
  end

end
