require "test_helper"

# The house half of a rollback (#426 3C checkpoint 3), against a recording
# docker: no daemon, no repository, no resident files. It runs outside
# transactional fixtures because the rollback refuses any open transaction.
class Agents::VmMigration::RollbackHomeTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  SELF = "c" * 64
  SNAPSHOT = "d" * 64
  PASSWORD = "repository-password-for-test".freeze
  UUID = "66666666-6666-4666-8666-666666666666".freeze
  SHAPE = { "entries" => 3, "shape" => "e" * 64 }.freeze
  MOUNTINFO = "1 2 0:1 /var/lib/docker/containers/#{SELF}/hostname /etc/hostname rw\n".freeze

  Status = Data.define(:exitstatus) do
    def success? = exitstatus.zero?
  end

  class FakeAdapter
    attr_reader :opened_read_only
    def repository_url = "rest:http://carry:secret@127.0.0.1:4242/"
    def probe_url = "http://127.0.0.1:4242/.carry-probe/#{'1' * 32}"
    def probe_answer = "carry-probe #{'1' * 32}"

    def open(_agent, deadline:, read_only: false)
      @opened_read_only = read_only
      yield self
    end
  end

  # Volumes are stateful (create keeps the first label, as Docker does);
  # everything else answers from the test's script.
  class FakeDocker
    attr_reader :calls, :volumes

    def initialize(test)
      @test = test
      @calls = []
      @volumes = {}
    end

    def capture3(*args, deadline:)
      args.shift if args.first.is_a?(Hash)
      @calls << args
      out, err, code = answer(args)
      [ out.to_s, err.to_s, Status.new(code) ]
    end

    def answer(argv)
      if argv[0, 3] == %w[docker volume create]
        label = argv.each_cons(2).find { |flag, value| flag == "--label" && value.start_with?("house.souls.rollback=") }&.last
        @volumes[argv.last] ||= label.to_s.delete_prefix("house.souls.rollback=")
        return [ "", "", 0 ]
      end
      if argv[0, 3] == %w[docker volume inspect]
        name = argv.last
        return [ "", "Error: No such volume: #{name}", 1 ] unless @volumes.key?(name)

        return [ "#{@volumes[name]}\n", "", 0 ]
      end
      return [ "#{SELF} true\n", "", 0 ] if argv[0, 3] == %w[docker container inspect]
      return [ "", "", 0 ] if argv[0, 2] == %w[docker rm]

      @test.respond(argv)
    end

    def runs = @calls.select { |argv| argv[0, 2] == %w[docker run] }
    def restores = runs.select { |argv| argv.include?("restore") }
  end

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(uuid: UUID, restic_password: PASSWORD, volume_map: nil, volume_rollback_generation: 0)
    @resources = Agents::Resources.new(@agent)
    @shapes = Agents::VmMigration::RollbackPlan::ROLES.to_h { |role| [ role.to_s, SHAPE.dup ] }
    @restored_shape = ->(_volume) { SHAPE }
    @restore_exit = 0
    @docker = FakeDocker.new(self)
    @adapter = FakeAdapter.new
  end

  teardown do
    AuditLog.where(auditable: @agent).delete_all
    @agent.update_columns(volume_map: nil, volume_rollback_generation: 0)
  end

  def snapshot_json(tags: Agents::VmMigration::RollbackHome.tags(@agent, @generation), paths: Agents::VmMigration::RollbackHome::PATHS,
                    hostname: "souls-house-rollback")
    JSON.generate([ { "id" => SNAPSHOT, "tags" => tags, "paths" => paths, "hostname" => hostname } ])
  end

  def respond(argv)
    return [ "carry-probe #{'1' * 32}", "", 0 ] if argv.include?("wget")
    return [ @snapshot_json || snapshot_json, "", 0 ] if argv.include?("snapshots")
    return [ "", "", @restore_exit ] if argv.include?("restore")
    if argv.include?("carry-shape")
      volume = argv.find { |arg| arg.start_with?("type=volume,src=") }.split(",")[1].delete_prefix("src=")
      shape = @restored_shape.call(volume)
      return [ "entries #{shape['entries']}\nshape #{shape['shape']}\n", "", 0 ]
    end

    [ "", "", 1 ]
  end

  def home(generation: @generation, shapes: @shapes)
    Agents::VmMigration::RollbackHome.new(@agent, generation:,
      snapshot: Agents::VmMigration::RollbackHome::Snapshot.new(snapshot_id: SNAPSHOT, shapes:),
      command: @docker, adapter: @adapter, mountinfo: -> { MOUNTINFO }, resources: @resources, nonce: "a" * 32)
  end

  def fresh_names(generation = @generation)
    @resources.derived_volumes.values.map { |name| "#{name}-rb#{generation}" }
  end

  test "restores all five into fresh volumes, read-only and verified, then swaps" do
    @generation = Agents::VmMigration::RollbackPlan.reserve!(@agent)
    fresh = Agents::VmMigration::RollbackPlan.new(@agent, generation: @generation, resources: @resources).fresh_map
    started = false
    result = home.call(start: ->(_) { started = true })

    assert result.ok?
    assert started
    assert @adapter.opened_read_only
    assert_equal fresh_names.sort, @docker.volumes.keys.sort
    assert(@docker.volumes.values.all? { |label| label == "#{UUID}/#{@generation}/#{'a' * 32}" })
    assert_equal 5, @docker.restores.size
    @docker.restores.each do |argv|
      assert_includes argv, "--verify"
      assert_includes argv, "--no-lock"
    end
    # Each role's restore writes only into its own fresh volume.
    @docker.restores.each do |argv|
      role = argv[argv.index("--target") + 1].delete_prefix("/rollback/")
      assert_includes argv, "type=volume,src=#{fresh.fetch(role)},dst=/rollback/#{role}"
    end
    assert(@docker.runs.none? { |argv| (argv & %w[backup init forget prune]).any? })
    assert_equal fresh, @agent.reload.volume_map
  end

  test "a generation that is not the latest reservation is refused before any IO" do
    stale = Agents::VmMigration::RollbackPlan.reserve!(@agent)
    Agents::VmMigration::RollbackPlan.reserve!(@agent)

    error = assert_raises(Agents::VmMigration::RollbackHome::Failed) { home(generation: stale).call }
    assert_match "latest reservation", error.message
    assert_empty @docker.calls
    assert_nil @agent.reload.volume_map
  end

  test "inside an open transaction nothing happens" do
    @generation = Agents::VmMigration::RollbackPlan.reserve!(@agent)
    Agent.transaction(joinable: false) do
      assert_raises(Agents::VmMigration::RollbackHome::Failed) { home.call }
    end
    assert_empty @docker.calls
  end

  test "a snapshot that is not this resident's and generation's creates no volume" do
    @generation = Agents::VmMigration::RollbackPlan.reserve!(@agent)
    @snapshot_json = snapshot_json(tags: Agents::VmMigration::RollbackHome.tags(@agent, @generation + 1))

    assert_raises(Agents::VmMigration::RollbackHome::Failed) { home.call }
    assert_empty @docker.volumes
    assert_empty @docker.restores
    assert_nil @agent.reload.volume_map
  end

  test "shapes that do not cover all five homes are refused before any IO" do
    @generation = Agents::VmMigration::RollbackPlan.reserve!(@agent)

    assert_raises(Agents::VmMigration::RollbackHome::Failed) { home(shapes: @shapes.except("work")).call }
    assert_empty @docker.calls
  end

  test "a restored home whose shape differs from the server's stops the rollback before the swap" do
    @generation = Agents::VmMigration::RollbackPlan.reserve!(@agent)
    work = "#{@resources.derived_volumes.fetch(:work)}-rb#{@generation}"
    @restored_shape = ->(volume) { volume == work ? SHAPE.merge("entries" => 2) : SHAPE }

    error = assert_raises(Agents::VmMigration::RollbackHome::Failed) { home.call }
    assert_match "work", error.message
    assert_nil @agent.reload.volume_map
    assert_not AuditLog.exists?(action: "vm_rollback_swap", auditable: @agent)
  end

  test "a failed restore stops the rollback before the swap" do
    @generation = Agents::VmMigration::RollbackPlan.reserve!(@agent)
    @restore_exit = 1

    assert_raises(Agents::VmMigration::RollbackHome::Failed) { home.call }
    assert_equal 1, @docker.restores.size
    assert_nil @agent.reload.volume_map
  end
end
