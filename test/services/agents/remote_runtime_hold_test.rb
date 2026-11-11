require "test_helper"

# #868: a VM resident's turn that arrives while its VM is restarting (a
# deploy roll or a credential refresh in flight) or while its runner's
# heartbeat is briefly late is held as a PendingWake and runs once the VM
# can take it, instead of being refused and dropped. Past
# RemoteRuntime::HOLD_LIMIT the run fails with the remote reason.
module Agents
  class RemoteRuntimeHoldTest < ActiveJob::TestCase

    IMAGE = "sha256:#{'d' * 64}".freeze

    setup do
      @user = users(:user_1)
      @agent = agents(:research_assistant)
      @agent.update!(runtime: "external", model_id: HouseInference::Offering::DEEPSEEK_MODEL_ID,
        container_name: "hk-agent-hold", trigger_bearer_token: "trig", runtime_ready_at: Time.current,
        uuid: SecureRandom.uuid_v7)
      @placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
      @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
      @enrollment.confirm_provider_server!(4242)
      @enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
      @enrollment.heartbeat!(reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
      @chat = @agent.account.chats.new(title: "Held during a restart", manual_responses: true)
      @chat.agents = [ @agent ]
      @chat.save!
      @chat.messages.create!(role: "user", user: @user, content: "Are you there?")
      @previous = ENV["SOULSHOUSE_DOMAIN"]
      ENV["SOULSHOUSE_DOMAIN"] = "souls.example"
    end

    teardown { ENV["SOULSHOUSE_DOMAIN"] = @previous }

    def live(&block)
      ResidentTurn.stub(:enabled?, true) do
        AgentRuntimeInteraction.stub(:live_activity_enabled?, true, &block)
      end
    end

    def begin_refresh
      RemoteRuntime.stub(:local_image_id, IMAGE) { RemoteRuntime.begin_refresh!(@agent) }
    end

    def answer(command, outcome, image: IMAGE)
      command.deliver!(now: Time.current)
      result = { "outcome" => outcome, "error" => (outcome == "done" ? nil : "boom") }.compact
      result["result"] = { "state" => "running", "image" => image }.compact if outcome == "done"
      command.record_result!(result, now: Time.current)
    end

    def tap_run
      AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat, wake_source_kinds: [ "human" ], requested_by_user: @user)
    end

    def run!(interaction)
      ExternalAgentResponseRequest.new(agent: @agent, chat: @chat, interaction: interaction,
        wake_source_kinds: [ "human" ]).call
    end

    test "a person's turn admitted during a restart is held, then released and run when the restart clears" do
      live do
        command = begin_refresh
        run = tap_run
        result = run!(run)

        assert_equal "remote_runtime_settling", result.dig(:body, "held")
        run.reload
        assert_equal "busy", run.execution_state, "held, not failed"
        assert_equal "Agents::RemoteRuntime::Settling", run.error_class
        assert_includes run.error_message, "a restart of its VM is in flight"
        assert_equal :neutral, run.streak_outcome
        assert_nil run.failure_category
        assert_enqueued_with(job: BusyRunRetryJob, args: [ run.id ])

        BusyRunRetryJob.perform_now(run.id)
        wake = PendingWake.open.find_by!(chat: @chat, agent: @agent)

        # Still restarting: not yet, and looked at again shortly.
        assert_enqueued_with(job: PendingWakeJob, args: [ @chat.id, @agent.id ]) do
          assert_nil PendingWake.release!(chat: @chat, agent: @agent)
        end
        assert_nil wake.reload.released_at
        assert_nil wake.dropped_at

        # The restart settles: the held wake is asked for at once ...
        answer(command, "done")
        assert_enqueued_with(job: PendingWakeJob, args: [ @chat.id, @agent.id ]) do
          assert_equal :done, RemoteRuntime.settle_refresh!(@placement.reload)
        end
        assert RemoteRuntime.dispatchable?(@agent)

        # ... released as one ordinary run, which reaches the VM.
        released = PendingWake.release!(chat: @chat, agent: @agent)
        assert_equal wake, released
        retry_run = released.released_interaction
        assert retry_run
        result = run!(retry_run)
        assert_equal 202, result[:status]
        turn = ResidentTurn.find_by!(agent_runtime_interaction: retry_run)
        assert_equal "runner://#{@enrollment.public_id}", turn.agent_runtime_interaction.endpoint_url
      end
    end

    test "a late heartbeat holds the turn the same way" do
      live do
        travel RunnerEnrollment::HEALTHY_WITHIN + 1.second
        assert RemoteRuntime.settling?(@agent)
        run = tap_run
        run!(run)
        assert_equal "busy", run.reload.execution_state
        assert_includes run.error_message, "heartbeat is late"
      end
    end

    test "a restart that has not finished within the hold limit fails the run with the remote reason" do
      live do
        begin_refresh
        run = tap_run
        run!(run)
        BusyRunRetryJob.perform_now(run.id)
        wake = PendingWake.open.find_by!(chat: @chat, agent: @agent)

        travel RemoteRuntime::HOLD_LIMIT + 1.second
        assert_not RemoteRuntime.settling?(@agent), "no longer a moment"
        # The wake is not held forever: it is released, and its run fails.
        released = PendingWake.release!(chat: @chat, agent: @agent)
        assert_equal wake, released
        failed = released.released_interaction
        run!(failed)

        failed.reload
        assert_equal "failed", failed.execution_state
        assert_equal "Agents::RemoteRuntime::Unavailable", failed.error_class
        assert_equal "runtime_unavailable", failed.failure_category
        assert_includes failed.failure_reason, "a restart of its VM has not finished in 15 minutes"
        assert_equal 0, ResidentTurn.where(agent: @agent).count
      end
    end

    test "a recovery start does not restart the hold: the limit counts from the first restart" do
      live do
        command = begin_refresh
        started = @placement.reload.refresh_snapshot["hold_started_at"]
        assert started

        travel 14.minutes
        assert RemoteRuntime.settling?(@agent)
        answer(command, "failed")
        assert_equal :recovering, RemoteRuntime.settle_refresh!(@placement.reload)
        assert_equal started, @placement.reload.refresh_snapshot["hold_started_at"], "kept across the recovery"

        travel 2.minutes
        assert_not RemoteRuntime.settling?(@agent), "16 minutes after the first restart, not 2 after the recovery"
        error = assert_raises(RemoteRuntime::Unavailable) { RemoteRuntime.require_dispatchable!(@agent) }
        assert_not_instance_of RemoteRuntime::Settling, error
        assert_includes error.message, "has not finished in 15 minutes"
      end
    end

    test "a scheduled wake that meets a restart is not held: it is refused with the remote reason, as before" do
      live do
        begin_refresh
        result = nil
        assert_no_difference -> { AgentRuntimeInteraction.count } do
          assert_no_difference -> { PendingWake.count } do
            result = ExternalAgentWakeRequest.new(agent: @agent).call
          end
        end
        assert_equal 0, result[:status]
        assert_includes result[:error], "a restart of its VM is in flight"
        assert_no_enqueued_jobs(only: [ BusyRunRetryJob, PendingWakeJob ])
      end
    end

    test "a placement that is gone fails with the remote reason, never the local runtime's" do
      live do
        @placement.update!(state: "retired")
        run = tap_run
        run!(run)

        run.reload
        assert_equal "failed", run.execution_state
        assert_equal "Agents::RemoteRuntime::Unavailable", run.error_class
        assert_includes run.error_message, "its VM placement is retired"
        assert_equal "runtime_unavailable", run.failure_category
        assert_no_enqueued_jobs(only: BusyRunRetryJob)
      end
    end

  end
end
