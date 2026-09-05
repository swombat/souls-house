require "test_helper"

class PromoteAgentJobTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "provisioning",
      birth_committed_at: Time.current,
      provisioning_started_at: Time.current,
      uuid: SecureRandom.uuid_v7,
      container_name: "hk-agent-test",
      container_image: "agent:test",
      trigger_bearer_token: "tr_test",
      outbound_api_token: "hx_test"
    )
  end

  test "seeds identity once, marks runtime ready, and queues orientation" do
    volume = FakeVolume.new(empty: true)
    sandbox = FakeSandbox.new(@agent)

    Agents::Volume.stub(:new, volume) do
      Agents::Sandbox.stub(:new, sandbox) do
        Agents::Config.stub(:backups_enabled?, false) do
          assert_enqueued_with(job: OrientNewAgentJob, args: [ @agent.id ]) do
            PromoteAgentJob.perform_now(@agent.id)
          end
        end
      end
    end

    @agent.reload
    assert volume.seeded
    assert_equal "external", @agent.runtime
    assert_predicate @agent.identity_seeded_at, :present?
    assert_predicate @agent.runtime_ready_at, :present?
  end

  test "retry preserves an existing identity volume" do
    volume = FakeVolume.new(empty: false)
    sandbox = FakeSandbox.new(@agent)

    Agents::Volume.stub(:new, volume) do
      Agents::Sandbox.stub(:new, sandbox) do
        Agents::Config.stub(:backups_enabled?, false) do
          PromoteAgentJob.perform_now(@agent.id)
        end
      end
    end

    assert_not volume.seeded
    assert_predicate @agent.reload.identity_seeded_at, :present?
  end

  test "failure remains retryable and never falls back to inline" do
    volume = FakeVolume.new(empty: true, seed_error: "seed failed")

    assert_raises Agents::Volume::SeedError do
      Agents::Volume.stub(:new, volume) do
        PromoteAgentJob.perform_now(@agent.id)
      end
    end

    @agent.reload
    assert_equal "provisioning", @agent.runtime
    assert_equal "unhealthy", @agent.health_state
    assert_match "seed failed", @agent.sandbox_last_error
    assert_predicate @agent.outbound_api_token, :present?
  end

  test "failure after spawning remains retryable without reseeding the committed identity" do
    volume = FakeVolume.new(empty: false)
    sandbox = FakeSandbox.new(@agent)
    original_birth = @agent.birth_committed_at
    Agents::Volume.stub(:new, volume) do
      Agents::Sandbox.stub(:new, sandbox) do
        Agents::Config.stub(:backups_enabled?, false) do
          OrientNewAgentJob.stub(:perform_later, ->(*) { raise "queue unavailable" }) do
            assert_raises(RuntimeError) { ProvisionAgentJob.perform_now(@agent.id) }
          end
        end
      end
    end
    assert_equal "provisioning", @agent.reload.runtime
    assert_equal original_birth, @agent.birth_committed_at
    assert_equal "unhealthy", @agent.health_state
    assert_not volume.seeded
  end

  class FakeVolume

    attr_reader :seeded

    def initialize(empty:, seed_error: nil)
      @empty = empty
      @seed_error = seed_error
      @seeded = false
    end

    def ensure! = true

    def empty? = @empty

    def seed_from_exporter!
      raise Agents::Volume::SeedError, @seed_error if @seed_error

      @seeded = true
      @empty = false
    end

  end

  class FakeSandbox

    def initialize(agent)
      @agent = agent
    end

    def spawn!
      @agent.update!(runtime: "external", health_state: "healthy")
    end

  end

end
