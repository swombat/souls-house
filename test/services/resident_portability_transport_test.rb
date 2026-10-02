require "test_helper"

class ResidentPortabilityTransportTest < ActiveSupport::TestCase

  Transport = Agents::Portability::Transport
  Error = Agents::Portability::Error
  Status = Struct.new(:exitstatus) do
    def success? = exitstatus == 0
  end

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(uuid: SecureRandom.uuid)
    @resources = Agents::Resources.new(@agent)
    @resources.define_singleton_method(:verify_existing!) { true }
    @transport = Transport.new(@agent)
    @transport.instance_variable_set(:@resources, @resources)
  end

  test "normal stopped policy is accepted absent is distinguished from daemon failure" do
    Open3.stub(:capture3, [ "exited unless-stopped\n", "", Status.new(0) ]) { assert @transport.stopped! }
    Open3.stub(:capture3, [ "running no\n", "", Status.new(0) ]) { assert_raises(Error) { @transport.stopped! } }
    Open3.stub(:capture3, [ "", "No such container", Status.new(1) ]) { assert @transport.stopped! }
    Open3.stub(:capture3, [ "", "Private daemon detail", Status.new(1) ]) do
      error = assert_raises(Error) { @transport.stopped! }
      refute_includes error.message, "Private"
    end
  end

  test "strict idle probe refuses active and unknown exits" do
    [ 0, 2, 127 ].each do |code|
      responses = [ [ "running\n", "", Status.new(0) ], [ "", "", Status.new(code) ] ]
      Open3.stub(:capture3, ->(*) { responses.shift }) { assert_raises(Error) { @transport.idle! } }
    end
    responses = [ [ "running\n", "", Status.new(0) ], [ "", "", Status.new(1) ] ]
    Open3.stub(:capture3, ->(*) { responses.shift }) { assert @transport.idle! }
  end

  test "capture never auto creates missing volume" do
    Open3.stub(:capture3, [ "", "missing", Status.new(1) ]) do
      assert_raises(Error) { @transport.capture("identity", StringIO.new) }
    end
  end

  test "Docker carrier is named labelled read-only and forcibly removed on transport failure" do
    commands = []
    # Real local pipes emulate the client; no Docker or production IO.
    original = Open3.method(:popen3)
    fake = ->(*args, **options, &block) do
      commands << args
      script = args[1] == "run" ? "STDERR.write('x'*100000); STDOUT.write('synthetic'); exit 1" : "exit 0"
      original.call("ruby", "-e", script, **options, &block)
    end
    Open3.stub(:capture3, [ "present", "", Status.new(0) ]) do
      Open3.stub(:popen3, fake) do
        assert_raises(Error) { @transport.capture("identity", StringIO.new) }
      end
    end
    run, cleanup = commands
    assert_includes run, "--read-only"
    assert_includes run, "house.souls.purpose=resident-portability"
    name = run[run.index("--name") + 1]
    assert_match(/portable-[0-9a-f]{16}\z/, name)
    assert_equal [ "docker", "rm", "-f", name ], cleanup
    refute run.join.include?(".chaos")
    refute run.join.include?("state")
  end
  test "timeout forcibly removes remote carrier not just Docker client" do
    commands = []
    original = Open3.method(:popen3)
    fake = ->(*args, **options, &block) do
      commands << args
      original.call("ruby", "-e", args[1] == "run" ? "sleep 20" : "exit 0", **options, &block)
    end
    timeout = ->(seconds, &block) do
      raise Timeout::Error if seconds == 60
      block.call
    end
    Open3.stub(:capture3, [ "present", "", Status.new(0) ]) do
      Open3.stub(:popen3, fake) do
        Timeout.stub(:timeout, timeout) { assert_raises(Error) { @transport.capture("identity", StringIO.new) } }
      end
    end
    run, cleanup = commands
    assert_equal [ "docker", "rm", "-f", run[run.index("--name") + 1] ], cleanup
  end

  test "ownership refusal precedes Docker IO" do
    @resources.define_singleton_method(:verify_existing!) { raise Agents::Resources::OwnershipError }
    Open3.stub(:capture3, ->(*) { flunk "Foreign resources cannot be inspected or mounted" }) do
      assert_raises(Agents::Resources::OwnershipError) { @transport.stopped! }
      assert_raises(Agents::Resources::OwnershipError) { @transport.capture("identity", StringIO.new) }
    end
  end

end
