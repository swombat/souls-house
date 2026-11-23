require "test_helper"

# Throwaway 50 (20 Nov 2026): a shared-host resident with no way to be
# retired, whose removed volumes the nightly backup brought back empty.
class AgentsRetireLocalTest < ActiveSupport::TestCase

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
      command = command.flatten
      @commands << command
      case command[1..2]
      in [ "volume", "inspect" ]
        @volumes.include?(command.last) ? ok : fail("Error: No such volume: #{command.last}")
      in [ "volume", "rm" ]
        return fail("Error: volume is in use") if @refuse_rm.include?(command.last)
        @volumes.delete?(command.last) ? ok : fail("Error: No such volume: #{command.last}")
      in [ "container", "inspect" ]
        @container ? [ "#{@container == :running}\n", "", OK.new(true) ] : fail("Error: No such container: x")
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

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(uuid: SecureRandom.uuid, runtime: "offline", active: false)
    @agent.agent_runtime_interactions.delete_all
    @names = Agents::Resources.new(@agent).volumes.values
  end

  def retire(docker, **options)
    Agents::DockerLocalGuard.stub(:check!, true) do
      Open3.stub(:capture3, docker.to_proc) do
        Agents::RetireLocal.call(@agent, reason: "throwaway for #969", **options)
      end
    end
  end

  test "retires a switched-off local resident: fences it, then removes and verifies every mapped volume" do
    docker = FakeDocker.new(@names, container: :stopped)

    assert_equal @names.sort, retire(docker).sort

    @agent.reload
    assert_equal "deprecated", @agent.runtime
    assert Agents::RetireLocal.retired_local?(@agent)
    assert_match "throwaway for #969", @agent.deprecation_reason
    assert_empty docker.volumes
    assert_nil docker.container
    assert_not Agent.externally_hosted.exists?(@agent.id)
    assert_equal %w[agent_retired_local agent_retired_local_cleaned],
      AuditLog.where(auditable: @agent).order(:id).pluck(:action)
  end

  test "refuses a resident that is switched on, busy, online, on a VM or running" do
    refusals = {
      "is still switched on" => -> { @agent.update_columns(active: true) },
      "is not offline" => -> { @agent.update_columns(runtime: "external") },
      "has a VM placement" => -> { AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 7) }
    }
    refusals.each do |message, arrange|
      @agent.update_columns(runtime: "offline", active: false)
      AgentPlacement.where(agent: @agent).delete_all
      arrange.call
      docker = FakeDocker.new(@names)
      error = assert_raises(Agents::RetireLocal::Refused) { retire(docker) }
      assert_match message, error.message
      assert_equal @names.to_set, docker.volumes, "nothing removed when #{message}"
    end

    @agent.update_columns(runtime: "offline", active: false)
    AgentPlacement.where(agent: @agent).delete_all
    error = assert_raises(Agents::RetireLocal::Refused) { retire(FakeDocker.new(@names, container: :running)) }
    assert_match "running container", error.message
    assert_equal "offline", @agent.reload.runtime
  end

  test "refuses while a backup holds the resident's quiesce lock" do
    # Its own session: the test's pool hands every checkout the same pinned
    # connection, and an advisory lock is reentrant within a session.
    other = ActiveRecord::Base.connection_pool.send(:new_connection)
    begin
      other.select_value(Backup::AgentRestic.quiesce_lock_sql("pg_advisory_lock", @agent))
      assert_raises(Agents::RetireLocal::Busy) { retire(FakeDocker.new(@names)) }
      assert_equal "offline", @agent.reload.runtime
    ensure
      other.select_value(Backup::AgentRestic.quiesce_lock_sql("pg_advisory_unlock", @agent))
      other.disconnect!
    end
  end

  test "a partial cleanup stays fenced, says what is left, and a second call finishes it" do
    docker = FakeDocker.new(@names)
    stuck = @names.last
    docker.refuse_rm << stuck

    error = assert_raises(Agents::RetireLocal::CleanupIncomplete) { retire(docker) }
    assert_match stuck, error.message
    assert_equal "deprecated", @agent.reload.runtime, "a Docker failure never returns it to the backup set"

    docker.refuse_rm.clear
    assert_equal [ stuck ], retire(docker)
    assert_empty docker.volumes
  end

  test "Docker not answering is never taken for absence" do
    docker = FakeDocker.new(@names)
    docker.define_singleton_method(:call) do |*command|
      command.flatten[1..2] == %w[volume inspect] ? [ "", "Cannot connect to the Docker daemon", FakeDocker::OK.new(false) ] : super(*command)
    end

    assert_raises(Agents::RetireLocal::CleanupIncomplete) { retire(docker) }
    assert_equal @names.to_set, docker.volumes
  end

  test "a retired local resident is not in the inline deprecation inventory and is never backed up" do
    retire(FakeDocker.new(@names))
    @agent.reload

    assert_not Agents::DeprecateInline.inventory.any? { |row| row[:id] == @agent.id }
    Agents::Config.stub(:backups_enabled?, true) do
      Open3.stub(:capture3, ->(*) { raise "docker reached" }) do
        assert_nil Backup::AgentResticJob.perform_now(@agent.id, force: true)
      end
    end
    assert_empty @agent.agent_backup_snapshots
  end

end
