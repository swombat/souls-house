require "test_helper"

module Agents
  class RemoteRuntimeTest < ActiveSupport::TestCase

    DIGEST_IMAGE = "sha256:#{'a' * 64}".freeze

    setup do
      @agent = agents(:research_assistant)
      @agent.update!(model_id: HouseInference::Offering::DEEPSEEK_MODEL_ID, trigger_bearer_token: "trig-secret")
      @placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
      @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
      @enrollment.confirm_provider_server!(4242)
      @enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
      @enrollment.heartbeat!(reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
    end

    def with_async(value = true, &block)
      ResidentTurn.stub(:enabled?, value, &block)
    end

    test "a ready VM placement with a healthy runner and async turns is dispatchable" do
      with_async do
        assert RemoteRuntime.dispatchable?(@agent)
        assert RuntimeLocation.dispatchable?(@agent)
        assert_not RuntimeLocation.local?(@agent)
        assert_equal "runner://#{@enrollment.public_id}", Endpoint.url_for(@agent)
      end
    end

    test "a VM Telegram turn carries persistent session policy and the delta through admission" do
      @agent.update!(runtime: "external", persistent_session: true)
      subscription = @agent.telegram_subscriptions.create!(user: users(:user_1), telegram_chat_id: 111)
      message = subscription.telegram_messages.create!(role: "user", text: "A VM conversation", sent_at: Time.current)
      with_async do
        result = ExternalAgentTelegramRequest.new(agent: @agent, subscription: subscription, telegram_message: message).call
        assert_equal 202, result[:status]
        turn = ResidentTurn.where(agent: @agent).last
        assert_equal "runner://#{@enrollment.public_id}", turn.agent_runtime_interaction.endpoint_url
        payload = JSON.parse(turn.payload)
        assert payload["persistent_session"]
        assert_equal @agent.runtime_session_policy.stringify_keys, payload["session_policy"]
        assert_includes payload["request_delta"], message.text
        assert_equal "#{@agent.uuid}-telegram-#{subscription.id}", payload["session_id"]
      end
    end

    test "every missing condition makes it not dispatchable, and nothing falls back to local" do
      cases = {
        "synchronous turns" => -> { },
        "placement pending" => -> { @placement.update!(state: "pending") },
        "runner revoked" => -> { @enrollment.revoke! },
        "runner silent" => -> { travel RunnerEnrollment::HEALTHY_WITHIN + 1.second }
      }
      cases.each do |name, breakage|
        @placement.update!(state: "ready")
        @enrollment.update!(revoked_at: nil, last_heartbeat_at: Time.current)
        breakage.call
        with_async(name != "synchronous turns") do
          assert_not RemoteRuntime.dispatchable?(@agent), name
          assert_not RuntimeLocation.dispatchable?(@agent), name
          assert_raises(RuntimeLocation::Unavailable, name) { Endpoint.url_for(@agent) }
        end
        travel_back
      end
    end

    test "the environment is the house's own values with the public origin, and only house inference runs" do
      with_env("SOULSHOUSE_DOMAIN" => "house.example") do
        env = RemoteRuntime.environment(@agent)
        assert_equal "house", env["AGENT_PROVIDER"]
        assert_equal "https://house.example", env["SOULSHOUSE_APP_URL"]
        assert_equal "https://house.example", env["SOULSHOUSE_ACTIVITY_ORIGIN"]
        assert_equal "trig-secret", env["TRIGGER_BEARER_TOKEN"]
        assert env.keys.none? { |key| key.end_with?("_API_KEY") }

        # Parity with a local resident: any model runs, with the account's own
        # keys unless it is house-funded.
        @agent.account.update!(anthropic_api_key: "sk-ant-account")
        @agent.update!(model_id: "anthropic/claude-opus-5-5")
        env = RemoteRuntime.environment(@agent)
        assert_equal Agents::Sandbox.chaos_provider_for(@agent), env["AGENT_PROVIDER"]
        assert_equal Agents::Sandbox.chaos_model_for(@agent), env["AGENT_DEFAULT_MODEL"]
        assert_equal "sk-ant-account", env["ANTHROPIC_API_KEY"]

        @agent.stub(:imported_home?, true) do
          assert_raises(RemoteRuntime::Unavailable) { RemoteRuntime.environment(@agent) }
        end
      end
    end

    test "start! carries the service manifest the local sandbox would copy in" do
      @agent.update!(uuid: SecureRandom.uuid_v7)
      with_env("SOULSHOUSE_DOMAIN" => "house.example") do
        payload = RemoteRuntime.start!(@agent, image: DIGEST_IMAGE).envelope["payload"]
        manifest = YAML.safe_load(payload.fetch("service_manifest"))
        assert_equal @agent.uuid, manifest["resident_id"]
        assert_equal 1, manifest["version"]
      end
    end

    test "provider logins are relayed through the runner and answered from its result" do
      waiter = Thread.new do
        command = nil
        20.times do
          command = RunnerCommand.where(kind: "provider_auth").last
          break if command
          sleep 0.05
        end
        command.deliver!(now: Time.current)
        command.record_result!({ "outcome" => "done", "result" => { "status" => 200, "body" => { "connected" => true } } },
          now: Time.current)
      end
      answer = RemoteRuntime.provider_auth!(@agent, method: "GET", path: "/auth/status", params: { provider: "anthropic", model: nil },
        wait: 5.seconds, poll: 0.05)
      waiter.join
      assert_equal({ "status" => 200, "body" => { "connected" => true } }, answer)
      payload = JSON.parse(RunnerCommand.where(kind: "provider_auth").last.payload_json.to_s.presence || "{}")
      assert_empty payload, "the payload is dropped once answered"
      assert_raises(RemoteRuntime::Unavailable) do
        RemoteRuntime.provider_auth!(@agent, method: "GET", path: "/auth/status", wait: 0.1.seconds, poll: 0.05)
      end
    end

    test "tailnet status is relayed through the runner, and an old runner's refusal says so" do
      answer_next = lambda do |result|
        Thread.new do
          command = nil
          40.times do
            command = RunnerCommand.where(kind: "tailnet", state: "queued").last
            break if command
            sleep 0.05
          end
          command.deliver!(now: Time.current)
          command.record_result!(result, now: Time.current)
        end
      end

      waiter = answer_next.call({ "outcome" => "done", "result" => { "ok" => true, "output" => "{}" } })
      answer = RemoteRuntime.tailnet!(@agent, action: "status", wait: 5.seconds, poll: 0.05)
      waiter.join
      assert_equal({ "ok" => true, "output" => "{}" }, answer)

      waiter = answer_next.call({ "outcome" => "refused", "error" => "command not allowed on this runner: 'tailnet'" })
      assert_raises(RemoteRuntime::RunnerTooOld) do
        RemoteRuntime.tailnet!(@agent, action: "up", wait: 5.seconds, poll: 0.05)
      end
      waiter.join

      waiter = answer_next.call({ "outcome" => "failed", "error" => "no resident agent-x on this host" })
      error = assert_raises(RemoteRuntime::Unavailable) do
        RemoteRuntime.tailnet!(@agent, action: "status", wait: 5.seconds, poll: 0.05)
      end
      waiter.join
      assert_not_kind_of RemoteRuntime::RunnerTooOld, error
      assert_match(/no resident/, error.message)

      assert_raises(ArgumentError) { RemoteRuntime.tailnet!(@agent, action: "down") }
    end

    test "start! needs an image ID and queues one start_resident for this placement" do
      @agent.update!(container_name: "agent-research-assistant")
      with_env("SOULSHOUSE_DOMAIN" => "house.example") do
        [ "registry.example/agent:latest", "helixkit-agent-runtime:latest", "sha256:abc" ].each do |image|
          assert_raises(ArgumentError, image) { RemoteRuntime.start!(@agent, image:) }
        end
        command = RemoteRuntime.start!(@agent, image: DIGEST_IMAGE)
        assert_equal "start_resident", command.kind
        assert_equal @placement.generation, command.generation
        payload = command.envelope["payload"]
        assert_equal DIGEST_IMAGE, payload["image"]
        assert_equal @agent.container_name, payload["container_name"]
      end
    end

    test "healthy only after the runner carried out a start, and not after a stop" do
      with_async do
        with_env("SOULSHOUSE_DOMAIN" => "house.example") do
          assert_not RemoteRuntime.healthy?(@agent)
          start = RemoteRuntime.start!(@agent, image: DIGEST_IMAGE)
          start.deliver!(now: Time.current)
          start.record_result!({ "outcome" => "done" }, now: Time.current)
          assert RemoteRuntime.healthy?(@agent)
          stop = RemoteRuntime.stop!(@agent)
          stop.deliver!(now: 1.second.from_now)
          stop.record_result!({ "outcome" => "done" }, now: 1.second.from_now)
          assert_not RemoteRuntime.healthy?(@agent)
        end
      end
    end

    test "a failed start is not healthy" do
      with_async do
        with_env("SOULSHOUSE_DOMAIN" => "house.example") do
          start = RemoteRuntime.start!(@agent, image: DIGEST_IMAGE)
          start.deliver!(now: Time.current)
          start.record_result!({ "outcome" => "failed", "error" => "no disk" }, now: Time.current)
          assert_not RemoteRuntime.healthy?(@agent)
        end
      end
    end

    private

    def with_env(values)
      previous = values.keys.to_h { |key| [ key, ENV[key] ] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| ENV[key] = value }
    end

  end
end
