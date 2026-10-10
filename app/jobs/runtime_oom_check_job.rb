# Runs when a resident's run ends badly (AgentRuntimeInteraction
# #enqueue_oom_check). If the kernel OOM-killed anything in the resident's
# container during the run, the count goes on the run, and the run then says
# "ran out of memory" rather than the "transport closed" that is all the
# runtime can see when the model process it was talking to is killed under it.
#
# The count is written only if, under the row lock and after the Docker
# query, the run still ended badly over the same window. A lost run can still
# complete late, before or during the query; and if it completes after the
# write, ran_out_of_memory? is false for a completed run, so nothing has to
# be undone.
#
# Local Docker residents only. A VM resident's container lives on its runner,
# which would have to report the same events back through its result.
class RuntimeOomCheckJob < ApplicationJob

  queue_as :default

  def perform(interaction_id)
    interaction = AgentRuntimeInteraction.includes(:agent).find_by(id: interaction_id)
    return unless interaction&.started_at && interaction.finished_at && interaction.agent && interaction.ended_badly?
    agent = interaction.agent
    return unless agent.container_name.present? && Agents::RuntimeLocation.local?(agent)

    finished_at = interaction.finished_at
    kills = Agents::Sandbox.new(agent).oom_kills_between(interaction.started_at, finished_at)
    return unless kills.to_i.positive?

    interaction.with_lock do
      next unless interaction.finished_at == finished_at && interaction.ended_badly?

      interaction.update!(container_oom_kills: kills)
    end
  rescue StandardError => error
    Rails.logger.warn("OOM check for interaction #{interaction_id} failed: #{error.class}: #{error.message}")
  end

end
