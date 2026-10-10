# Runs when a resident's run ends in failure (AgentRuntimeInteraction
# #enqueue_oom_check). If the kernel OOM-killed anything in the resident's
# container during the run, the run's error says so: "ran out of memory",
# not the "transport closed" that is all the runtime can see when the model
# process it was talking to is killed under it.
#
# Local Docker residents only. A VM resident's container lives on its runner,
# which would have to report the same events back through its result.
class RuntimeOomCheckJob < ApplicationJob

  ERROR_CLASS = "Agents::ContainerOutOfMemory".freeze

  queue_as :default

  def perform(interaction_id)
    interaction = AgentRuntimeInteraction.includes(:agent).find_by(id: interaction_id)
    return unless interaction&.started_at && interaction.finished_at && interaction.agent
    return if interaction.error_class == ERROR_CLASS
    agent = interaction.agent
    return unless agent.container_name.present? && Agents::RuntimeLocation.local?(agent)

    kills = Agents::Sandbox.new(agent).oom_kills_between(interaction.started_at, interaction.finished_at)
    return unless kills.to_i.positive?

    interaction.update!(error_class: ERROR_CLASS, error_message: message(interaction, agent, kills))
  rescue StandardError => error
    Rails.logger.warn("OOM check for interaction #{interaction_id} failed: #{error.class}: #{error.message}")
  end

  private

  def message(interaction, agent, kills)
    text = "Ran out of memory: the kernel killed #{kills} #{'process'.pluralize(kills)} in this resident's " \
      "container (limit #{agent.container_memory_mb} MB) during the run."
    previous = [ interaction.error_class, interaction.error_message ].compact_blank.join(": ")
    previous.present? ? "#{text} The runtime reported: #{previous.truncate(300)}" : text
  end

end
