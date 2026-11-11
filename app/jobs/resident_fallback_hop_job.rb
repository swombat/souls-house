# The fallback dispatch of a run whose subscription refused it before it
# started, on the asynchronous path (#690, ResidentFallback::Hop): the
# refused ResidentTurn was retired as hopped, and the run is still open.
#
# Everything is asked again first: the switch, the policy (and that it still
# names the model the hop was opened on), and the source that authorised the
# run. If any says no, the run ends with the subscription's refusal exactly
# as it would have without the hop, including the room's limit line.
class ResidentFallbackHopJob < ApplicationJob

  def perform(turn_id)
    turn = ResidentFallbackTurn.find_by(id: turn_id)
    run = turn&.fallback_interaction
    return unless run && turn.chat
    # Claimed once, under the run's lock: a second delivery of this job
    # finds the run already on its fallback lane and does nothing, instead
    # of dispatching again and ending the shared run as busy (Mira #887).
    return unless claim!(turn, run)

    reason = refusal(turn, run)
    return end_with_refusal(turn, run, reason) if reason

    options = { interaction: run, wake_source_kinds: run.wake_source_kinds, requested_at: run.response_requested_at, fallback_turn: turn }
    options[:requested_by] = run.requested_by if run.requested_by.present?
    ExternalAgentResponseRequest.new(agent: turn.agent, chat: turn.chat, **options).call
  end

  private

  def claim!(turn, run)
    run.with_lock do
      next false if run.finished_at? || run.resident_turn.present? || ResidentFallback::Lane.fallback_session?(run.session_id)

      run.update!(session_id: ResidentFallback::Lane.session_id(turn.agent, turn.chat, fallback: true))
      true
    end
  end

  def refusal(turn, run)
    return "fallback_off" unless Setting.instance.paid_fallback_enabled?

    decision = ResidentFallback::Decision.for(turn.agent.reload)
    return decision.code unless decision.ok?
    return "fallback_model_unavailable" unless decision.policy.model_id == turn.fallback_model_id

    ResidentFallback::Hop.source_refusal(run)
  end

  # The run ends as the subscription answered it, and the hopped turn's
  # completion runs as it would have (the room's limit line, safeguard
  # bookkeeping).
  def end_with_refusal(turn, run, reason)
    Rails.logger.info("[ResidentFallbackHopJob] #{turn.agent_id} hop not dispatched: #{reason}")
    result = turn.primary_result.to_h
    body = result["body"].is_a?(Hash) ? result["body"] : {}
    hopped = ResidentTurn.where(agent_runtime_interaction_id: run.id).where.not(hopped_at: nil).order(:id).last
    run.with_lock do
      next if run.finished_at?

      run.update!(error_class: nil, error_message: nil, provider: turn.primary_provider, model: turn.primary_model,
        session_id: ResidentFallback::Lane.session_id(turn.agent, turn.chat, fallback: false))
      run.record_result!(status: result["status"].to_i, body: body)
    end
    ResidentTurnCompletion.new(hopped, result.merge("body" => body)).call if hopped
  end

end
