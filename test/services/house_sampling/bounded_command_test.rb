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
    child = File.read(pid_file).to_i
    assert_raises(Errno::ESRCH) { Process.kill(0, child) }
  ensure
    FileUtils.remove_entry(marker) if marker
  end

  test "a missing command is a failed result, not an exception" do
    result = HouseSampling::BoundedCommand.run("definitely-not-a-command-#{SecureRandom.hex(3)}", timeout: 1)
    assert_not result.ok
  end

end
