require "test_helper"

class HouseSampling::HostReaderTest < ActiveSupport::TestCase

  setup do
    @proc = Dir.mktmpdir
    File.write(File.join(@proc, "loadavg"), "1.50 1.25 0.75 3/900 12345\n")
    File.write(File.join(@proc, "meminfo"), "MemTotal:       1000 kB\nMemFree:         100 kB\nMemAvailable:    400 kB\n")
  end

  teardown { FileUtils.remove_entry(@proc) }

  def write_stat(user, idle)
    File.write(File.join(@proc, "stat"), <<~STAT)
      cpu  #{user} 0 0 #{idle} 0 0 0 0 0 0
      cpu0 1 0 0 1 0 0 0 0 0 0
      cpu1 1 0 0 1 0 0 0 0 0 0
      intr 1
    STAT
  end

  test "reads load, memory and cores, and needs a previous sample for CPU" do
    write_stat(100, 900)
    metrics = HouseSampling::HostReader.new(proc_root: @proc).call
    assert_equal [ 1.5, 1.25, 0.75 ], metrics.values_at("load_1", "load_5", "load_15")
    assert_equal 1_024_000, metrics["mem_total_bytes"]
    assert_equal 409_600, metrics["mem_available_bytes"]
    assert_equal 2, metrics["cores"]
    assert_nil metrics["cpu_percent"]
    assert metrics["disk_total_bytes"].to_i.positive?
  end

  test "CPU percent is busy time over total time since the previous sample" do
    write_stat(100, 900)
    first = HouseSampling::HostReader.new(proc_root: @proc).call
    write_stat(400, 1600) # +300 busy, +700 idle
    second = HouseSampling::HostReader.new(proc_root: @proc).call(previous: first)
    assert_equal 30.0, second["cpu_percent"]
  end

  test "a counter that went backwards (reboot) gives no CPU reading" do
    write_stat(100, 900)
    second = HouseSampling::HostReader.new(proc_root: @proc).call(previous: { "cpu_total_jiffies" => 5000, "cpu_idle_jiffies" => 4000 })
    assert_nil second["cpu_percent"]
  end

end
