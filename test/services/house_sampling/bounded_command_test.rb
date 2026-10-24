require "test_helper"

class HouseSampling::BoundedCommandTest < ActiveSupport::TestCase

  test "returns the output of a command that finishes in time" do
    result = HouseSampling::BoundedCommand.run("echo", "hello", timeout: 5)
    assert result.ok
    assert_not result.timed_out
    assert_equal "hello\n", result.stdout
  end

  test "a slow child is stopped at the deadline and reaped" do
    marker = Dir.mktmpdir
    pid_file = File.join(marker, "pid")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = HouseSampling::BoundedCommand.run("sh", "-c", "echo $$ > #{pid_file}; exec sleep 30", timeout: 0.3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert result.timed_out
    assert_not result.ok
    assert_operator elapsed, :<, 3, "waited #{elapsed.round(2)}s for a 0.3s deadline"
    assert_gone(pid_file)
  ensure
    FileUtils.remove_entry(marker) if marker
  end

  test "a missing command is a failed result, not an exception" do
    result = HouseSampling::BoundedCommand.run("definitely-not-a-command-#{SecureRandom.hex(3)}", timeout: 1)
    assert_not result.ok
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [ result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started ]
  end

  # Gone means no longer running. An orphan is reparented to whatever reaps
  # orphans; in a container whose PID 1 doesn't, a killed descendant stays a
  # zombie (state Z), so "the pid still exists" is not the question.
  def assert_gone(pid_file)
    pid = File.read(pid_file).to_i
    assert pid.positive?
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    sleep 0.02 while running?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    assert_not running?(pid), "descendant #{pid} is still running"
  end

  def running?(pid)
    state = File.read("/proc/#{pid}/stat").split(") ").last.to_s[0]
    !%w[Z X].include?(state)
  rescue Errno::ENOENT, Errno::ESRCH
    false
  end

  test "a descendant that ignores TERM and keeps the pipes open is killed even after its leader exits" do
    dir = Dir.mktmpdir
    pid_file = File.join(dir, "pid")
    # The leader waits on a child that ignores TERM; TERM ends the leader,
    # and the child (still holding the pipes) needs the group KILL.
    script = %(sh -c 'trap "" TERM; echo $$ > #{pid_file}; exec sleep 30' & wait)
    result, seconds = elapsed { HouseSampling::BoundedCommand.run("sh", "-c", script, timeout: 0.3) }

    assert result.timed_out
    assert_operator seconds, :<, 0.3 + 2 * HouseSampling::BoundedCommand::GRACE
    assert_gone(pid_file)
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "the deadline covers the pipes: a leader that exits leaving a pipe-holding descendant still returns on time" do
    dir = Dir.mktmpdir
    pid_file = File.join(dir, "pid")
    script = %(echo hello; sh -c 'echo $$ > #{pid_file}; exec sleep 30' &)
    result, seconds = elapsed { HouseSampling::BoundedCommand.run("sh", "-c", script, timeout: 0.5) }

    assert result.timed_out
    assert_not result.ok
    assert_equal "hello\n", result.stdout
    assert_operator seconds, :<, 0.5 + HouseSampling::BoundedCommand::GRACE
    assert_gone(pid_file)
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "large output is read in full" do
    result = HouseSampling::BoundedCommand.run("sh", "-c", "head -c 1048576 /dev/zero; head -c 1048576 /dev/zero >&2", timeout: 10)
    assert result.ok
    assert_equal 1_048_576, result.stdout.bytesize
  end

end
