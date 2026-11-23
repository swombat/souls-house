require "test_helper"

# Throwaway 50 (20 Nov 2026): a shared-host resident with no way to be
# retired, whose removed volumes the nightly backup brought back empty.
class AgentsRetireLocalTest < ActiveSupport::TestCase

  # RetireLocal refuses an open transaction, as its fence must commit
  # before Docker deletes anything.
  self.use_transactional_tests = false

  # A Docker that knows volumes and one container by name.
  class FakeDocker

    attr_reader :volumes, :commands
    attr_accessor :container, :refuse_rm

    OK = Struct.new(:success?)

    def initialize(volumes, container: nil)
      @volumes = volumes.to_set
      @container = container
      @commands = []
      @refuse_rm = []
    end

    def call(*command)
      command = command.flatten.reject { |part| part.is_a?(Hash) }
      @commands << command
      # Ownership label reads (Resources#verify_existing! on a namespaced
      # instance): this checkout's fingerprint on what exists.
      if command.include?("--format") && command[command.index("--format") + 1].include?("house.souls.checkout")
        present = command[1] == "volume" ? @volumes.include?(command.last) : @container
        return present ? [ "#{LocalInstance.current.fingerprint}\n", "", OK.new(true) ] : fail("Error: No such object: #{command.last}")
      end
      case command[1..2]
      in [ "volume", "inspect" ]
        @volumes.include?(command.last) ? ok : fail("Error: No such volume: #{command.last}")
      in [ "volume", "rm" ]
        return fail("Error: volume is in use") if @refuse_rm.include?(command.last)
        @volumes.delete?(command.last) ? ok : fail("Error: No such volume: #{command.last}")
      in [ "container", "inspect" ]
        @container ? [ "#{@container == :running}\n", "", OK.new(true) ] : fail("Error: No such container: x")
      in [ "inspect", "--format" ]
        fail("Error: No such object: x")
      in [ "rm", _ ]
        @container = nil
        ok
      else
        raise "unexpected docker command: #{command.inspect}"
      end
    end

    def to_proc = method(:call).to_proc

    private

    def ok = [ "", "", OK.new(true) ]
    def fail(message) = [ "", message, OK.new(false) ]

  end

  KEPT = %w[uuid runtime active deprecated_at deprecation_reason trigger_bearer_token github_resident_import_id].freeze

  setup do
    @agent = agents(:research_assistant)
    @kept = @agent.attributes.slice(*KEPT)
    @agent.update_columns(uuid: SecureRandom.uuid, runtime: "offline", active: false)
    assert_not @agent.agent_runtime_interactions.active.exists?
    @names = Agents::Resources.new(@agent).volumes.values
  end

  teardown do
    AuditLog.where(auditable: @agent).delete_all
    AgentPlacement.where(agent_id: @agent.id).delete_all
    AgentBackupSnapshot.where(agent_id: @agent.id).delete_all
    @agent.update_columns(@kept)
  end

  def retire(docker, **options)
    Agents::DockerLocalGuard.stub(:check!, true) do
      Open3.stub(:capture3, docker.to_proc) do
        Agents::RetireLocal.call(@agent.reload, reason: "throwaway for #969", **options)
      end
    end
  end

  test "retires a switched-off local resident: commits the fence, then removes and verifies every mapped volume" do
    docker = FakeDocker.new(@names, container: :stopped)

    assert_equal @names.sort, retire(docker).sort

    @agent.reload
    assert_equal "deprecated", @agent.runtime
    assert Agents::RetireLocal.retired_local?(@agent)
    assert_empty docker.volumes
    assert_nil docker.container
    assert_not Agent.externally_hosted.exists?(@agent.id)
    fence = Agents::RetireLocal.fence_record(@agent)
    assert_equal Agents::Resources.new(@agent).volumes.transform_keys(&:to_s), fence.data["volumes"]
    assert_equal %w[agent_retired_local agent_retired_local_cleaned],
      AuditLog.where(auditable: @agent).order(:id).pluck(:action)
  end

  test "refuses inside an open transaction, before touching anything" do
    docker = FakeDocker.new(@names)
    Agent.transaction do
      error = assert_raises(Agents::RetireLocal::Refused) { retire(docker) }
      assert_match "open transaction", error.message
    end
    assert_empty docker.commands
    assert_equal "offline", @agent.reload.runtime
  end

  test "refuses a resident that is switched on, online, on a VM, imported or running" do
    refusals = {
      "is still switched on" => -> { @agent.update_columns(active: true) },
      "is not offline" => -> { @agent.update_columns(runtime: "external") },
      "has a VM placement" => -> { AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 7) },
      # Same object across reloads: no import row is needed to carry the id.
      "GitHub import" => -> { @agent.define_singleton_method(:github_resident_import_id) { 424242 } }
    }
    refusals.each do |message, arrange|
      @agent.update_columns(runtime: "offline", active: false)
      AgentPlacement.where(agent: @agent).delete_all
      arrange.call
      docker = FakeDocker.new(@names)
      error = assert_raises(Agents::RetireLocal::Refused) { retire(docker) }
      assert_match message, error.message
      assert_equal @names.to_set, docker.volumes, "nothing removed when #{message}"
      assert_not Agents::RetireLocal.fence_record(@agent)
    end

    @agent.singleton_class.remove_method(:github_resident_import_id)
    @agent.update_columns(runtime: "offline", active: false)
    AgentPlacement.where(agent: @agent).delete_all
    error = assert_raises(Agents::RetireLocal::Refused) { retire(FakeDocker.new(@names, container: :running)) }
    assert_match "running container", error.message
    assert_equal "offline", @agent.reload.runtime
  end

  test "Docker resources that are not this checkout's are refused before the fence or any inspection" do
    docker = FakeDocker.new(@names)
    foreign = ->(**) { raise Agents::Resources::OwnershipError, "Docker volume x has foreign or missing ownership labels" }
    original = Agents::Resources.instance_method(:verify_existing!)
    Agents::Resources.define_method(:verify_existing!, &foreign)
    begin
      assert_raises(Agents::Resources::OwnershipError) { retire(docker) }
    ensure
      Agents::Resources.define_method(:verify_existing!, original)
    end
    assert_empty docker.commands
    assert_equal "offline", @agent.reload.runtime
    assert_not Agents::RetireLocal.fence_record(@agent)
  end

  test "a partial cleanup stays fenced; a retry rechecks everything and removes only what the fence recorded" do
    docker = FakeDocker.new(@names)
    stuck = @names.last
    docker.refuse_rm << stuck

    error = assert_raises(Agents::RetireLocal::CleanupIncomplete) { retire(docker) }
    assert_match stuck, error.message
    assert_equal "deprecated", @agent.reload.runtime, "a Docker failure never returns it to the backup set"

    docker.refuse_rm.clear
    @agent.update_columns(active: true)
    assert_raises(Agents::RetireLocal::Refused) { retire(docker) }
    assert_equal [ stuck ], docker.volumes.to_a

    @agent.update_columns(active: false)
    assert_equal [ stuck ], retire(docker)
    assert_empty docker.volumes
  end

  test "a deprecated resident without a local retirement record is never cleaned up" do
    @agent.update_columns(runtime: "deprecated", deprecation_reason: "Retired shared-host resident: forged")
    docker = FakeDocker.new(@names)
    error = assert_raises(Agents::RetireLocal::Refused) { retire(docker) }
    assert_match "not retired as a local resident", error.message
    assert_equal @names.to_set, docker.volumes
    assert_not Agents::RetireLocal.retired_local?(@agent)
  end

  test "Docker not answering is never taken for absence" do
    docker = FakeDocker.new(@names)
    docker.define_singleton_method(:call) do |*command|
      command.flatten[1..2] == %w[volume inspect] ? [ "", "Cannot connect to the Docker daemon", FakeDocker::OK.new(false) ] : super(*command)
    end

    # Caught by the ownership check, before the fence.
    assert_raises(Agents::Resources::OwnershipError) { retire(docker) }
    assert_equal @names.to_set, docker.volumes
    assert_equal "offline", @agent.reload.runtime
  end

  # Two real sessions and the real quiesce path: a backup holding the
  # resident makes retirement busy, and once retired, a forced backup takes
  # nothing and records nothing.
  test "retirement and the backup's actual quiesce path exclude each other" do
    docker = FakeDocker.new(@names)
    holding = Queue.new
    release = Queue.new
    backup = nil
    Open3.stub(:capture3, docker.to_proc) do
      backup = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Backup::AgentRestic.paused(Agent.find(@agent.id)) do
            holding << true
            release.pop
          end
        end
      end
      # Bounded: a backup thread that raised before signalling fails here,
      # not at the CI job's timeout (Mira, #1105).
      assert holding.pop(timeout: 10), "the backup never took the quiesce lock"
      assert_raises(Agents::RetireLocal::Busy) { Agents::RetireLocal.call(@agent.reload, reason: "x") }
      release << true
      backup.join
    end
    assert_equal "offline", @agent.reload.runtime

    retire(docker)
    Agents::Config.stub(:backups_enabled?, true) do
      Open3.stub(:capture3, ->(*) { raise "docker reached" }) do
        assert_nil Backup::AgentResticJob.perform_now(@agent.id, force: true)
      end
    end
    assert_empty @agent.agent_backup_snapshots
  ensure
    release << true if backup&.alive?
    backup&.join
  end

  test "a retired local resident is not in the inline deprecation inventory and is never backed up" do
    retire(FakeDocker.new(@names))
    @agent.reload

    assert_not Agents::DeprecateInline.inventory.any? { |row| row[:id] == @agent.id }
    assert_not Agent.externally_hosted.exists?(@agent.id), "the nightly selector never picks it"
  end

end
