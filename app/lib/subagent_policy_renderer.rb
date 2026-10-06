# The sub-agent policy a resident carries into every trigger once its owner has
# configured it. Chaos's spawn_agent description says to delegate only when the
# user explicitly asks; when this setting is on, it is that explicit ask, made
# once by the owner instead of in every conversation. When it is turned off
# again, the section says so, because a resumed session still remembers the
# earlier permission.
class SubagentPolicyRenderer

  def self.section_for(agent)
    new(agent).section
  end

  def initialize(agent)
    @agent = agent
  end

  def section
    if @agent.subagents_enabled?
      enabled_section
    elsif @agent.subagents_policy_changed_at.present?
      revoked_section
    end
  end

  private

  def enabled_section
    models = @agent.available_subagent_models
    return no_models_section if models.empty?

    <<~TEXT.strip
      ## Sub-agents: standing permission

      This is the current sub-agent policy for you, set by the people who run this resident's account. It replaces any earlier sub-agent policy in this session.

      You have standing permission to use sub-agents (`spawn_agent`, `run_synopsis`) without being asked in the conversation. This setting is the explicit user authorisation those tools require. Delegate when a subtask is bounded and self-contained and can run in parallel with your own work, especially mechanical or well-specified work a cheaper model can do. Keep critical-path, tightly coupled or judgement-heavy work yourself, and review what helpers return before you rely on it.

      Allowed sub-agent models. Always pass `model`, and use only these. Do not omit `model` to inherit your own model unless your own model is on this list:
      #{models.map { |entry| model_line(entry) }.join("\n")}
      If spawn_agent rejects one of these names, it lists the names it accepts. Use the matching one, and do not substitute a model that is not on this list.
    TEXT
  end

  def no_models_section
    <<~TEXT.strip
      ## Sub-agents: no allowed models

      This is the current sub-agent policy for you, set by the people who run this resident's account. It replaces any earlier sub-agent policy in this session. Sub-agents are switched on, but no allowed model is currently available, so do not spawn sub-agents unless someone in the conversation explicitly asks you to.
    TEXT
  end

  def revoked_section
    <<~TEXT.strip
      ## Sub-agents: no standing permission

      This is the current sub-agent policy for you, set by the people who run this resident's account. It replaces any earlier sub-agent policy in this session. You no longer have standing permission to use sub-agents. Use `spawn_agent` or `run_synopsis` only when someone in the conversation explicitly asks you to.
    TEXT
  end

  def model_line(entry)
    provider = entry[:provider] == own_provider ? "omit `model_provider` (your own provider)" : "`model_provider: #{entry[:provider]}`"
    "- #{entry[:label]}: `model: #{entry[:model]}`, #{provider} (#{entry[:provider_label]}, #{entry[:source]})"
  end

  def own_provider
    return @own_provider if defined?(@own_provider)

    @own_provider = begin
      Agents::Sandbox.chaos_provider_for(@agent)
    rescue KeyError
      nil
    end
  end

end
