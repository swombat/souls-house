require "test_helper"

# The house carry snapshot's orchestration (#426 slice 3C, checkpoint 2),
# against a recording docker: no daemon, no repository, no resident files.
class Agents::VmMigrationCarrySnapshotTest < ActiveSupport::TestCase

  SELF = "c" * 64
  SNAPSHOT = "d" * 64
  PASSWORD = "repository-password-for-test".freeze
  CREDENTIAL = "adapter-credential-for-test".freeze
  SHAPE = "entries 3\nshape #{'e' * 64}\n".freeze

  Status = Data.define(:exitstatus) do
    def success? = exitstatus.zero?
  end

  class FakeAdapter

    attr_reader :opened
    def repository_url = "rest:http://carry:#{CREDENTIAL}@127.0.0.1:4242/"
    def probe_url = "http://127.0.0.1:4242/.carry-probe/#{'1' * 32}"
    def probe_answer = "carry-probe #{'1' * 32}"

    def open(_agent, deadline:)
      @opened = deadline
      yield self
    end

  end

  class FakeDocker

    attr_reader :calls
    def initialize(&respond)
      @respond = respond
      @calls = []
    end

    def capture3(*args, deadline:)
      env = args.first.is_a?(Hash) ? args.shift : {}
      @calls << { env:, argv: args, deadline: }
      out, code = @respond.call(args)
      [ out.to_s, code.to_i.zero? ? "" : "No such container", Status.new(code.to_i) ]
    end

    def runs = @calls.select { |call| call[:argv][0, 2] == %w[docker run] }
    def restic(subcommand) = runs.select { |call| call[:argv].include?(subcommand) && call[:argv].include?("rest.connections=1") }

  end

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(uuid: "44444444-4444-4444-8444-444444444444", restic_password: PASSWORD, container_image: "dtenner/souls-house-agent:abc123")
    @resources = Agents::Resources.new(@agent)
    @resources.define_singleton_method(:verify_existing!) { |**| true }
    @tags = [ "agent=44444444-4444-4444-8444-444444444444", "carry=v1", "generation=3", "runtime=dtenner/souls-house-agent:abc123" ]
    @snapshot = { "id" => SNAPSHOT, "tags" => @tags, "paths" => %w[/carry/chaos /carry/state], "hostname" => "souls-house-carry" }
    @config_exit = 0
  end

  def happy(argv)
    return [ "#{SELF} true\n", 0 ] if argv[0, 3] == %w[docker container inspect]
    return [ "", 0 ] if argv[0, 2] == %w[docker rm]
    return [ SHAPE, 0 ] if argv.include?("carry-shape")
    return [ "carry-probe #{'1' * 32}", 0 ] if argv.include?("wget")
    return [ "", @config_exit ] if argv.include?("cat")
    return [ "", 0 ] if argv.include?("init") || argv.include?("check")
    return [ %({"message_type":"status"}\n{"message_type":"summary","snapshot_id":"#{SNAPSHOT}"}\n), 0 ] if argv.include?("backup")
    return [ JSON.generate([ @snapshot ]), 0 ] if argv.include?("snapshots")

    [ "", 1 ]
  end

  def snapshot(docker, mountinfo: "1 2 0:1 /var/lib/docker/containers/#{SELF}/hostname /etc/hostname rw\n")
    Agents::VmMigration::CarrySnapshot.new(@agent, generation: 3, command: docker, adapter: FakeAdapter.new, mountinfo: -> { mountinfo },
      resources: @resources)
  end

  test "a carry takes both shapes, then backs up through the adapter and checks what it wrote" do
    docker = FakeDocker.new { |argv| happy(argv) }
    result = snapshot(docker).call
    assert_equal SNAPSHOT, result.snapshot_id
    assert_equal({ "entries" => 3, "shape" => "e" * 64 }, result.shapes["chaos"])
    assert_equal %w[chaos state], result.shapes.keys
    assert_equal @tags, result.tags

    order = docker.runs.map { |call| (%w[carry-shape wget cat init backup snapshots check] & call[:argv]).first }
    assert_equal %w[carry-shape carry-shape wget cat backup snapshots check], order
    backup = docker.restic("backup").sole[:argv]
    @tags.each { |tag| assert_includes backup.each_cons(2).to_a, [ "--tag", tag ] }
    assert_includes backup, "type=volume,src=#{@resources.volumes[:chaos]},dst=/carry/chaos,readonly"
    assert_includes backup, "type=volume,src=#{@resources.volumes[:state]},dst=/carry/state,readonly"
    docker.runs.each do |call|
      assert_includes call[:argv], "--read-only"
      assert_includes call[:argv].each_cons(2).to_a, [ "--cap-drop", "ALL" ]
      network = call[:argv][call[:argv].index("--network") + 1]
      assert_equal(call[:argv].include?("carry-shape") ? "none" : "container:#{SELF}", network)
    end
  end

  test "no secret reaches a command line; the tools get them through docker's environment" do
    docker = FakeDocker.new { |argv| happy(argv) }
    snapshot(docker).call
    docker.calls.each do |call|
      refute call[:argv].join(" ").include?(PASSWORD), "password on argv"
      refute call[:argv].join(" ").include?(CREDENTIAL), "adapter credential on argv"
    end
    docker.restic("backup").each do |call|
      assert_equal PASSWORD, call[:env]["RESTIC_PASSWORD"]
      assert_includes call[:env]["RESTIC_REPOSITORY"], CREDENTIAL
      assert_includes call[:argv].each_cons(2).to_a, %w[-e RESTIC_PASSWORD]
    end
  end

  test "a missing repository is created; any other failure to read it stops the carry" do
    @config_exit = 10
    docker = FakeDocker.new { |argv| happy(argv) }
    snapshot(docker).call
    assert_equal 1, docker.restic("init").size

    @config_exit = 1
    docker = FakeDocker.new { |argv| happy(argv) }
    error = assert_raises(Agents::VmMigration::CarrySnapshot::Failed) { snapshot(docker).call }
    assert_match(/could not be read/, error.message)
    assert_empty docker.restic("backup")
    assert_empty docker.restic("init")
  end

  test "a snapshot that is not exactly this resident's, generation's and runtime's is refused" do
    [ { "tags" => @tags - [ "generation=3" ] + [ "generation=2" ] }, { "tags" => @tags + [ "extra" ] },
      { "paths" => %w[/carry/chaos] }, { "id" => "f" * 64 }, { "hostname" => "elsewhere" } ].each do |change|
      @snapshot = @snapshot.merge(change)
      docker = FakeDocker.new { |argv| happy(argv) }
      error = assert_raises(Agents::VmMigration::CarrySnapshot::Failed) { snapshot(docker).call }
      assert_match(/not of this resident/, error.message, change.inspect)
      assert_empty docker.restic("check")
      @snapshot = { "id" => SNAPSHOT, "tags" => @tags, "paths" => %w[/carry/chaos /carry/state], "hostname" => "souls-house-carry" }
    end
  end

  test "outside a resolvable, running house container nothing runs" do
    [ "", "/containers/#{SELF}/hostname\n/containers/#{'9' * 64}/hosts\n" ].each do |mountinfo|
      docker = FakeDocker.new { |argv| happy(argv) }
      error = assert_raises(Agents::VmMigration::CarrySnapshot::Failed) { snapshot(docker, mountinfo:).call }
      assert_equal Agents::VmMigration::CarrySnapshot::NOT_IN_CONTAINER, error.message
      assert_empty docker.runs
    end
    docker = FakeDocker.new { |argv| argv[0, 3] == %w[docker container inspect] ? [ "#{SELF} false", 0 ] : happy(argv) }
    assert_raises(Agents::VmMigration::CarrySnapshot::Failed) { snapshot(docker).call }
    assert_empty docker.runs
  end

  test "a tool that cannot reach the adapter stops the carry before the repository is touched" do
    docker = FakeDocker.new { |argv| argv.include?("wget") ? [ "something else", 0 ] : happy(argv) }
    error = assert_raises(Agents::VmMigration::CarrySnapshot::Failed) { snapshot(docker).call }
    assert_match(/could not reach/, error.message)
    assert_empty docker.restic("cat")
  end

  test "a backup that does not report exactly one snapshot fails, and every tool is removed" do
    docker = FakeDocker.new { |argv| argv.include?("backup") ? [ %({"message_type":"summary"}\n), 0 ] : happy(argv) }
    assert_raises(Agents::VmMigration::CarrySnapshot::Failed) { snapshot(docker).call }
    names = docker.runs.map { |call| call[:argv][call[:argv].index("--name") + 1] }
    removed = docker.calls.select { |call| call[:argv][0, 3] == %w[docker rm -f] }.map { |call| call[:argv].last }
    assert_equal names, removed
    names.each { |name| assert_match(/\Asouls-house-carry-[0-9a-f]{24}\z/, name) }
  end

  test "shapes are parsed strictly" do
    parse = ->(text) { Agents::VmMigration::CarrySnapshot.parse_shape(text) }
    assert_equal({ "entries" => 0, "shape" => "0" * 64 }, parse.call("entries 0\nshape #{'0' * 64}\n"))
    [ "", "entries 01\nshape #{'0' * 64}\n", "entries 1\nshape #{'0' * 63}\n", "entries 1\nshape #{'0' * 64}\nextra\n",
      "shape #{'0' * 64}\nentries 1\n" ].each do |text|
      assert_raises(Agents::VmMigration::CarrySnapshot::Failed) { parse.call(text) }
    end
  end

  test "the house uses the VM runner's pinned restic image" do
    runner = File.read(Rails.root.join("host-runner/backup_proxy.py"))[/^RESTIC_IMAGE = "([^"]+)"/, 1]
    assert_equal runner, Agents::VmMigration::CarrySnapshot::IMAGE
  end

end
