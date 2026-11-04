require "test_helper"

# #426 slice 3C: the runtime inventory reads only what its script prints.
class Agents::PortabilityTransportInventoryTest < ActiveSupport::TestCase

  Transport = Agents::Portability::Transport
  Error = Agents::Portability::Error
  PROBES = Transport::INVENTORY_PROBES.fetch(:chaos)

  test "parses sizes, the named paths present and the session map's entry count" do
    found = Transport.parse_inventory("files 12\nbytes 25769803776\nhas chaos.sqlite\nhas oauth-runtime/chaos.sqlite\nsessions 3\n", PROBES)
    assert_equal({ files: 12, bytes: 25_769_803_776, present: %w[chaos.sqlite oauth-runtime/chaos.sqlite], sessions: 3 }, found)
    assert_nil Transport.parse_inventory("files 0\nbytes 0\n", PROBES)[:sessions], "no session map is not zero sessions"
  end

  test "refuses anything it did not ask for, rather than guessing" do
    [ "files 1\n", "bytes 1\n", "files 1\nbytes 1\nhas ../../etc\n", "files 1\nbytes 1\nhas secrets.txt\n",
      "files 1\nbytes 1\nsomething else\n", "files -1\nbytes 1\n",
      "files 12\nbytes 1\nfiles 0\n", "files 1\nbytes 1\nbytes 0\n", "files 1\nbytes 1\nsessions 3\nsessions 0\n",
      "files 1\nbytes 1\nhas chaos.sqlite\nhas chaos.sqlite\n" ].each do |text|
      error = assert_raises(Error, text) { Transport.parse_inventory(text, PROBES) }
      assert_equal "Resident runtime state cannot be measured", error.message
    end
  end

  test "the script fails on any failed traversal or stat, and prints sizes, never names" do
    script = Transport::INVENTORY_SCRIPT
    assert_equal "set -eo pipefail", script.lines.first.strip
    assert_includes script, "-exec stat -c %s {} +"
    assert_includes script, "-exec stat -c x {} + | wc -l", "one line per session file whatever its name"
    assert_not_includes script, "-print"
    assert_not_includes script, "-type f | wc -l"
  end

  test "a bounded command past its deadline is killed, not waited for" do
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, "pid")
      started = Agents::BoundedCommand.now
      assert_raises(Agents::BoundedCommand::TimedOut) do
        Agents::BoundedCommand.capture3("sh", "-c", "echo $$ > #{pidfile}; exec sleep 30", deadline: started + 0.3)
      end
      assert_operator Agents::BoundedCommand.now - started, :<, 5
      pid = Integer(File.read(pidfile).strip, 10)
      assert_raises(Errno::ESRCH, "the command's process group was killed") { Process.kill(0, pid) }
    end
    stdout, _, status = Agents::BoundedCommand.capture3("echo", "fine", deadline: Agents::BoundedCommand.now + 5)
    assert status.success?
    assert_equal "fine\n", stdout
  end

  # Mira's round-3 case: the leader exits at once, a backgrounded child keeps
  # the pipes open. Waiting for the leader alone returned success after the
  # child finished; the drain must share the deadline and the group must be
  # killed though its leader is gone.
  test "a leader that exits while its child holds the pipes is still bounded" do
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, "pid")
      started = Agents::BoundedCommand.now
      assert_raises(Agents::BoundedCommand::TimedOut) do
        Agents::BoundedCommand.capture3("sh", "-c", "sleep 30 & echo $! > #{pidfile}; exit 0", deadline: started + 0.3)
      end
      assert_operator Agents::BoundedCommand.now - started, :<, 3
      pid = Integer(File.read(pidfile).strip, 10)
      deadline = Agents::BoundedCommand.now + 2
      sleep 0.05 while File.exist?("/proc/#{pid}") && !File.read("/proc/#{pid}/stat").split[2].eql?("Z") && Agents::BoundedCommand.now < deadline
      alive = File.exist?("/proc/#{pid}") && !File.read("/proc/#{pid}/stat").split[2].eql?("Z")
      refute alive, "the orphaned child in the command's group was killed"
    end
  end

  test "the ownership and volume inspects count against an inventory's timeout" do
    resources = Struct.new(:volumes) { def verify_existing!(deadline:) = (@deadline = deadline) }.new({ state: "synthetic-state" })
    transport = Transport.new(Agent.new)
    transport.instance_variable_set(:@resources, resources)
    transport.define_singleton_method(:stream) { |*, **| flunk "no time was left to read the volume" }
    real = Agents::BoundedCommand.method(:capture3)
    slow_inspect = ->(*args, deadline: nil) { real.call("sleep", "30", deadline:) }
    started = Agents::BoundedCommand.now
    error = Agents::BoundedCommand.stub(:capture3, slow_inspect) do
      assert_raises(Error) { transport.inventory(:state, timeout: 0.3) }
    end
    assert_equal "Reading the resident's volumes ran out of time", error.message
    assert_operator Agents::BoundedCommand.now - started, :<, 5
    assert_in_delta started + 0.3, resources.instance_variable_get(:@deadline), 0.2, "verify_existing! gets the same deadline"
  end

  test "only the Chaos and state volumes can be inventoried" do
    error = assert_raises(Error) { Transport.new(Agent.new).inventory(:identity) }
    assert_equal "Unsupported runtime volume", error.message
  end

end
