# The turn half of ChaosTriggerClient for a resident on a VM (#238): the same
# three calls and the same { status:, body: } answers, carried by
# RunnerCommands instead of HTTP. ResidentTurnPollJob uses it unchanged.
#
# Each call reuses an unanswered command of the same kind for the same turn
# instead of queueing another, so a slow runner never gets a second submit.
# It waits a bounded time for the runner's answer. Anything other than the
# runner carrying the command out (failed, refused, unknown, no answer yet)
# comes back as a 5xx, which the poll job records and retries. It never comes
# back as a 404: a 404 from turn_status is what licenses a submission, and
# only the resident's own trigger server may say that.
class RemoteTriggerClient

  WAIT = 20.seconds
  STEP = 0.5

  def initialize(enrollment:, agent:, resident_turn:, sleeper: ->(seconds) { sleep(seconds) }, clock: -> { Time.current })
    @enrollment = enrollment
    @agent = agent
    @resident_turn = resident_turn
    @sleeper = sleeper
    @clock = clock
  end

  def submit_turn(id, payload, ledger_id:)
    relay("submit_turn", id, body: payload, ledger_id:)
  end

  def turn_status(id)
    relay("turn_status", id)
  end

  def cancel_turn(id, ledger_id:, payload: nil)
    relay("cancel_turn", id, body: payload, ledger_id:)
  end

  # Console containment (ResidentTurn#resolve_after_containment!) is not
  # available on a VM in this slice.
  def resolve_turn(_id)
    { status: 501, body: { "status" => "error", "error" => "containment is not available for VM residents" } }
  end

  private

  attr_reader :enrollment, :agent, :resident_turn

  def relay(kind, dispatch_id, body: nil, ledger_id: nil)
    raise ArgumentError, "invalid dispatch id" unless dispatch_id.to_s.match?(/\A[0-9a-f-]{36}\z/)

    command = pending(kind) || RunnerCommand.enqueue!(
      enrollment:, kind:, resident_turn:,
      payload: { "container_name" => agent.container_name, "dispatch_id" => dispatch_id,
                 "ledger_id" => ledger_id, "body" => body }.compact
    )
    answer(wait_for(command))
  end

  def pending(kind)
    RunnerCommand.where(runner_enrollment_id: enrollment.id, resident_turn_id: resident_turn.id, kind:)
      .where.not(state: RunnerCommand::TERMINAL).order(:id).first
  end

  def wait_for(command)
    deadline = @clock.call + WAIT
    loop do
      command = RunnerCommand.uncached { RunnerCommand.find(command.id) }
      return command if command.terminal? || @clock.call >= deadline

      @sleeper.call(STEP)
    end
  end

  def answer(command)
    unless command.terminal?
      return { status: 504, body: { "status" => "error", "error" => "runner has not answered yet" } }
    end

    relayed = command.result.is_a?(Hash) ? command.result["result"] : nil
    if command.state == "done" && relayed.is_a?(Hash) && relayed["status"].is_a?(Integer) && relayed["body"].is_a?(Hash)
      { status: relayed["status"], body: relayed["body"] }
    elsif command.state == "unknown"
      { status: 503, body: { "status" => "error", "error" => "runner cannot confirm the outcome" } }
    else
      { status: 502, body: { "status" => "error", "error" => command.result.to_h["error"].to_s.first(500) } }
    end
  end

end
