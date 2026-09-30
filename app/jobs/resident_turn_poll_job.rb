class ResidentTurnPollJob < ApplicationJob

  queue_as :resident_dispatch
  discard_on ActiveRecord::RecordNotFound

  def perform(id)
    claimed = ResidentTurn.pending.where(id: id).where.not(state: "queued")
      .where("poll_claimed_until IS NULL OR poll_claimed_until < ?", Time.current)
      .update_all(poll_claimed_until: 45.seconds.from_now)
    return unless claimed == 1
    turn = ResidentTurn.find(id)
    return if turn.finished_at? || turn.state == "queued"
    interaction = turn.agent_runtime_interaction
    client = ChaosTriggerClient.new(interaction.endpoint_url, turn.agent.trigger_bearer_token)
    response = client.turn_status(turn.dispatch_id)
    ledger_id = response.dig(:body, "ledger_id")
    unless ledger_id.is_a?(String) && ledger_id.match?(/\A[0-9a-f-]{36}\z/)
      turn.record_check!(diagnostic: "Runtime did not provide a durable ledger (HTTP #{response[:status]})")
      return
    end
    if turn.ledger_id && turn.ledger_id != ledger_id
      turn.record_check!(state: "unknown", diagnostic: "Runtime ledger replaced; execution outcome unconfirmed")
      return
    end
    # Persist ledger identity BEFORE submission. A lost POST response followed
    # by a replaced volume can then never cause automatic replay.
    turn.update!(ledger_id: ledger_id) unless turn.ledger_id
    if response[:status] == 404
      # Idempotent resubmission is safe only against a persistent ledger.
      # A missing record after confirmed acceptance means lost runtime state,
      # not permission to replay external side effects.
      if turn.state != "starting"
        turn.record_check!(state: "unknown", diagnostic: "Accepted execution missing from runtime ledger")
        return
      end
      turn.prepare!
      response = if turn.cancel_requested_at?
        client.cancel_turn(turn.dispatch_id, payload: JSON.parse(turn.payload), ledger_id: turn.ledger_id)
      else
        client.submit_turn(turn.dispatch_id, JSON.parse(turn.payload), ledger_id: turn.ledger_id)
      end
    end
    body = response[:body]
    if response[:status].in?([ 200, 202 ]) && body["id"] == turn.dispatch_id
      case body["state"]
      when "finished", "cancelled"
        turn.finish!(body.fetch("result"), cancelled: body["state"] == "cancelled")
      when "accepted", "running"
        turn.record_check!(state: "running")
        client.cancel_turn(turn.dispatch_id, ledger_id: turn.ledger_id) if turn.cancel_requested_at?
      when "unknown"
        turn.record_check!(state: "unknown", diagnostic: "Runtime cannot confirm process exit")
      end
    else
      # 409 may mean a legacy invocation still owns this runtime session;
      # never turn an ambiguous response into available capacity.
      turn.record_check!(diagnostic: "Runtime did not confirm acceptance (HTTP #{response[:status]})")
    end
  rescue StandardError => error
    turn&.record_check!(diagnostic: "Runtime check failed (#{error.class})")
    Rails.logger.warn("Resident turn #{id} reconciliation failed: #{error.class}")
  ensure
    ResidentTurn.where(id: id).update_all(poll_claimed_until: nil) if claimed == 1
  end

end
