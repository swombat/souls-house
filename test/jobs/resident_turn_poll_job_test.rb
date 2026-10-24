require "test_helper"
require "webmock/minitest"

class ResidentTurnPollJobTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(trigger_bearer_token: "synthetic")
    interaction = AgentRuntimeInteraction.create!(
      agent: @agent, trigger_kind: "wake", session_id: "synthetic",
      started_at: Time.current, endpoint_url: "https://runtime.example.test"
    )
    @turn = ResidentTurn.enqueue!(interaction, { session_id: "synthetic", request: "prompt" })
    ResidentTurn.admit!
    @url = "https://runtime.example.test/turns/#{@turn.dispatch_id}"
    @ledger = SecureRandom.uuid
  end

  def status(state, **extra)
    { id: @turn.dispatch_id, ledger_id: @ledger, state: state, **extra }.to_json
  end

  test "lost submission reply retries the identical id and payload on the same ledger" do
    stub_request(:get, @url).to_return(status: 404, body: { ledger_id: @ledger }.to_json)
    stub_request(:post, @url).to_timeout
    ResidentTurnPollJob.perform_now(@turn.id)
    assert_equal @ledger, @turn.reload.ledger_id
    assert_nil @turn.finished_at
    stub_request(:get, @url).to_return(status: 200, body: status("running"))
    ResidentTurnPollJob.perform_now(@turn.id)
    assert_equal "running", @turn.reload.state
    assert_requested :post, @url, times: 1
  end

  test "lost ledger cannot replay even when acceptance reply was lost" do
    @turn.update!(ledger_id: SecureRandom.uuid)
    stub_request(:get, @url).to_return(status: 404, body: { ledger_id: @ledger }.to_json)
    ResidentTurnPollJob.perform_now(@turn.id)
    assert_equal "unknown", @turn.reload.state
    assert_not_requested :post, @url
  end

  test "old runtime does not cause a synchronous fallback" do
    stub_request(:get, @url).to_return(status: 404, body: "{}")
    ResidentTurnPollJob.perform_now(@turn.id)
    assert_equal "starting", @turn.reload.state
    assert_not_requested :post, /runtime\.example\.test/
  end

  test "terminal ledger result completes accounting even when callback was lost" do
    stub_request(:get, @url).to_return(status: 200, body: status("finished",
      result: { status: 200, body: { status: "ok", returncode: 0 } }))
    ResidentTurnPollJob.perform_now(@turn.id)
    assert_equal "finished", @turn.reload.state
    assert_equal "ok", @turn.agent_runtime_interaction.reload.runtime_status
    assert @turn.agent_runtime_interaction.finished_at?
  end

  test "unknown remains reserved beyond the old timeout grace" do
    stub_request(:get, @url).to_return(status: 200, body: status("unknown"))
    ResidentTurnPollJob.perform_now(@turn.id)
    travel 2.days do
      assert_equal 1, ResidentTurn.occupying_capacity.count
      assert_nil @turn.reload.finished_at
    end
  end

  test "cancellation before acceptance creates a runtime tombstone without launching" do
    @turn.update!(cancel_requested_at: Time.current)
    stub_request(:get, @url).to_return(status: 404, body: { ledger_id: @ledger }.to_json)
    stub_request(:delete, @url)
      .with(headers: { "X-Resident-Ledger-ID" => @ledger })
      .to_return(status: 200, body: status("cancelled",
        result: { status: 409, body: { status: "cancelled" } }))
    ResidentTurnPollJob.perform_now(@turn.id)
    assert_equal "cancelled", @turn.reload.state
    assert_not_requested :post, @url
  end

  test "a failed cancellation transport cannot regress running to starting" do
    @turn.update!(cancel_requested_at: Time.current)
    stub_request(:get, @url).to_return(status: 200, body: status("running"))
    stub_request(:delete, @url).to_timeout
    ResidentTurnPollJob.perform_now(@turn.id)
    assert_equal "running", @turn.reload.state
  end

  test "an admitted turn is withdrawn after placement leaves local without submitting to its stored endpoint" do
    AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "pending")
    stub_request(:get, @url).to_return(status: 404, body: { ledger_id: @ledger }.to_json)
    stub_request(:delete, @url)
      .with(headers: { "X-Resident-Ledger-ID" => @ledger })
      .to_return(status: 200, body: status("cancelled",
        result: { status: 409, body: { status: "cancelled" } }))

    ResidentTurnPollJob.perform_now(@turn.id)

    assert_equal "cancelled", @turn.reload.state
    assert_not_requested :post, @url
    assert_requested :delete, @url
  end

  test "retired local placement withdraws before submission and retains capacity until cancellation confirmed" do
    AgentPlacement.create!(agent: @agent, backend: "local", state: "retired")
    stub_request(:get, @url).to_return(status: 404, body: { ledger_id: @ledger }.to_json)
    stub_request(:delete, @url).to_timeout

    ResidentTurnPollJob.perform_now(@turn.id)

    assert @turn.reload.cancel_requested_at?
    assert_nil @turn.finished_at
    assert_equal 1, ResidentTurn.occupying_capacity.count
    assert_not_requested :post, @url
  end

  test "a placement change does not prevent reconciling already accepted work" do
    AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "pending")
    @turn.update!(state: "running", ledger_id: @ledger)
    stub_request(:get, @url).to_return(status: 200, body: status("finished",
      result: { status: 200, body: { status: "ok", returncode: 0 } }))

    ResidentTurnPollJob.perform_now(@turn.id)

    assert_equal "finished", @turn.reload.state
    assert_not_requested :post, @url
  end

  class RemoteTurnTest < ActiveSupport::TestCase

    # A resident on a VM goes through the same poll job, with commands for
    # HTTP. The "runner" here answers each command with what the resident's
    # trigger server would have said.
    setup do
      @agent = agents(:research_assistant)
      @agent.update!(trigger_bearer_token: "synthetic")
      placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
      @enrollment, token = RunnerEnrollment.mint!(placement:)
      @enrollment.confirm_provider_server!(4242)
      @enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
      @enrollment.heartbeat!(reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
      ResidentTurn.stub(:enabled?, true) do
        interaction = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", session_id: "synthetic",
          started_at: Time.current, endpoint_url: Agents::Endpoint.url_for(@agent))
        @turn = ResidentTurn.enqueue!(interaction, { session_id: "synthetic", request: "prompt" })
        ResidentTurn.admit!
      end
      @ledger = SecureRandom.uuid
    end

    def run_with_runner(&answers)
      sleeper = lambda do |_seconds|
        command = RunnerCommand.where.not(state: RunnerCommand::TERMINAL).order(:id).first
        next unless command

        command.deliver!(now: Time.current) if command.state == "queued"
        status, body = answers.call(command)
        command.record_result!({ "outcome" => "done", "result" => { "status" => status, "body" => body } }, now: Time.current)
      end
      ResidentTurn.stub(:enabled?, true) do
        RemoteTriggerClient.stub(:new, ->(**kwargs) { RemoteTriggerClient.allocate.tap { |c| c.send(:initialize, **kwargs, sleeper:) } }) do
          ResidentTurnPollJob.perform_now(@turn.id)
        end
      end
    end

    test "status 404 then submission through the runner, then running" do
      run_with_runner do |command|
        case command.kind
        when "turn_status" then [ 404, { "ledger_id" => @ledger } ]
        when "submit_turn" then [ 202, { "id" => @turn.dispatch_id, "ledger_id" => @ledger, "state" => "accepted" } ]
        end
      end
      assert_equal %w[turn_status submit_turn], RunnerCommand.order(:id).pluck(:kind)
      assert_equal "running", @turn.reload.state
      assert_equal @ledger, @turn.ledger_id
    end

    test "a runner that cannot confirm never leads to a submission" do
      ResidentTurn.stub(:enabled?, true) do
        sleeper = lambda do |_seconds|
          command = RunnerCommand.where.not(state: RunnerCommand::TERMINAL).order(:id).first
          next unless command

          command.deliver!(now: Time.current) if command.state == "queued"
          command.record_result!({ "outcome" => "unknown", "error" => "restarted" }, now: Time.current)
        end
        RemoteTriggerClient.stub(:new, ->(**kwargs) { RemoteTriggerClient.allocate.tap { |c| c.send(:initialize, **kwargs, sleeper:) } }) do
          ResidentTurnPollJob.perform_now(@turn.id)
        end
      end
      assert_equal %w[turn_status], RunnerCommand.pluck(:kind)
      assert_nil @turn.reload.finished_at
    end

    test "a turn recorded against a replaced runner is never sent to the new one" do
      @enrollment.revoke!
      replacement, token = RunnerEnrollment.mint!(placement: @enrollment.agent_placement)
      replacement.confirm_provider_server!(4242)
      replacement.enroll!(token:, public_key: Base64.strict_encode64("n" * 32), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
      replacement.heartbeat!(reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
      ResidentTurn.stub(:enabled?, true) do
        assert Agents::RemoteRuntime.dispatchable?(@agent)
        ResidentTurnPollJob.perform_now(@turn.id)
      end
      assert_equal 0, RunnerCommand.count
      assert_nil @turn.reload.finished_at
    end

    test "a VM resident is never reached synchronously" do
      endpoint = @turn.agent_runtime_interaction.endpoint_url
      ResidentTurn.stub(:enabled?, false) do
        error = assert_raises(ArgumentError) do
          ChaosTriggerClient.new(endpoint, "token").request_response(conversation_id: nil, requested_by: "x", session_id: "s", request: "r")
        end
        assert_match(/asynchronous/, error.message)
      end
    end

    test "the real wake entrypoint enqueues a turn for a VM resident" do
      endpoint = @turn.agent_runtime_interaction.endpoint_url
      assert endpoint.start_with?("runner://")
      interaction = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", session_id: "entry",
        started_at: Time.current, endpoint_url: endpoint)
      response = ResidentTurn.stub(:enabled?, true) do
        ChaosTriggerClient.new(endpoint, "token").request_response(
          conversation_id: nil, requested_by: "x", session_id: "entry", request: "r", interaction:)
      end
      assert_equal 202, response[:status]
      queued = ResidentTurn.find_by!(dispatch_id: response[:body]["dispatch_id"])
      assert_equal interaction, queued.agent_runtime_interaction
    end

    # The dispatch behind this turn stops standing (discarded, author gone,
    # past the no-new-starts boundary) after the submit was queued.
    def with_dispatch_withdrawn
      ResidentTurn.alias_method :__deliverable_for_test, :dispatch_deliverable?
      ResidentTurn.define_method(:dispatch_deliverable?) { false }
      yield
    ensure
      ResidentTurn.alias_method :dispatch_deliverable?, :__deliverable_for_test
      ResidentTurn.remove_method :__deliverable_for_test
    end

    # Queues a submit the runner never collects: status 404, then the
    # submission waits unanswered and the poll job records a 504.
    def queue_undelivered_submit
      sleeper = lambda do |_seconds|
        command = RunnerCommand.where(kind: "turn_status").where.not(state: RunnerCommand::TERMINAL).first
        next unless command

        command.deliver!(now: Time.current)
        command.record_result!({ "outcome" => "done", "result" => { "status" => 404, "body" => { "ledger_id" => @ledger } } }, now: Time.current)
      end
      clock_start = Time.current
      ticks = 0
      clock = -> { clock_start + (ticks += 1).seconds }
      ResidentTurn.stub(:enabled?, true) do
        RemoteTriggerClient.stub(:new, ->(**kwargs) { RemoteTriggerClient.allocate.tap { |c| c.send(:initialize, **kwargs, sleeper:, clock:) } }) do
          ResidentTurnPollJob.perform_now(@turn.id)
        end
      end
      submit = RunnerCommand.find_by!(kind: "submit_turn")
      assert_equal "queued", submit.state
      submit
    end

    test "a cancelled turn's queued submit is withdrawn at handoff, and recovery sends a cancel" do
      submit = queue_undelivered_submit
      @turn.cancel!
      assert @turn.reload.cancel_requested_at?

      ResidentTurn.stub(:enabled?, true) { assert_nil @enrollment.poll!(nonce: SecureRandom.hex(16)) }
      assert_equal "refused", submit.reload.state
      assert_nil submit.delivered_at

      run_with_runner do |command|
        case command.kind
        when "turn_status" then [ 404, { "ledger_id" => @ledger } ]
        when "cancel_turn" then [ 200, { "id" => @turn.dispatch_id, "ledger_id" => @ledger, "state" => "cancelled", "result" => {} } ]
        when "submit_turn" then flunk "a withdrawn turn was submitted"
        end
      end
      assert_equal 1, RunnerCommand.where(kind: "cancel_turn").count
      assert_equal 1, RunnerCommand.where(kind: "submit_turn").count
    end

    test "a queued submit whose dispatch no longer stands is withdrawn at handoff" do
      submit = queue_undelivered_submit
      ResidentTurn.stub(:enabled?, true) do
        with_dispatch_withdrawn do
          assert_nil @enrollment.poll!(nonce: SecureRandom.hex(16))
        end
      end
      assert_equal "refused", submit.reload.state
      assert @turn.reload.cancel_requested_at?
    end

    test "a delivered submit keeps its uncertainty: cancellation never refuses it" do
      submit = queue_undelivered_submit
      ResidentTurn.stub(:enabled?, true) do
        assert_equal submit.public_id, @enrollment.poll!(nonce: SecureRandom.hex(16))["id"]
        @turn.cancel!
        travel RunnerCommand::REDELIVER_AFTER + 1.second
        assert_equal submit.public_id, @enrollment.poll!(nonce: SecureRandom.hex(16))["id"]
      end
      assert_equal "delivered", submit.reload.state
    end

    test "a suspended memory vault stops a VM resident's runtime as it stops a local one" do
      @agent.create_memory_vault! unless @agent.memory_vault
      @agent.memory_vault.update!(suspended_at: Time.current)
      ResidentTurn.stub(:enabled?, true) do
        assert Agents::RemoteRuntime.dispatchable?(@agent)
        assert_raises(Agents::Sandbox::SandboxError) do
          Agents::Sandbox.new(@agent.reload).with_runtime { flunk "must not yield" }
        end
      end
    end

    test "health follows the runner and the last start; cleanup never touches local Docker" do
      ResidentTurn.stub(:enabled?, true) do
        job = AgentHealthCheckJob.new
        assert_not job.send(:healthy?, @agent)
        start = RunnerCommand.enqueue!(enrollment: @enrollment, kind: "start_resident", payload: {})
        start.deliver!(now: Time.current)
        start.record_result!({ "outcome" => "done" }, now: Time.current)
        assert job.send(:healthy?, @agent), "a started VM resident is healthy without any local HTTP check"
        Agents::Sandbox.stub(:new, ->(*) { flunk "local sandbox touched" }) do
          Agents::Config.stub(:cold_start?, true) do
            ResidentTurnCleanupJob.perform_now(@agent.id)
            assert_not job.send(:intentionally_cold?, @agent)
          end
        end
      end
    end

    test "a revoked runner gets no command at all" do
      @enrollment.revoke!
      ResidentTurn.stub(:enabled?, true) { ResidentTurnPollJob.perform_now(@turn.id) }
      assert_equal 0, RunnerCommand.count
      assert_nil @turn.reload.finished_at
    end

  end

end
