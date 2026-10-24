module HouseSampling
  # Reads the host this process runs on. /proc/loadavg, /proc/stat and
  # /proc/meminfo are host-wide even inside a container (no lxcfs here), so
  # load, CPU and memory are the house host as a whole. Disk is `df /` in
  # the container: the filesystem backing Docker's overlay, which is not
  # necessarily the host's root filesystem or every host mount.
  class HostReader

    def initialize(proc_root: "/proc")
      @proc_root = proc_root
    end

    def call(previous: nil)
      metrics = {}
      metrics.merge!(load_average)
      metrics.merge!(cpu(previous))
      metrics.merge!(memory)
      metrics.merge!(disk)
      metrics
    end

    private

    def read(name)
      File.read(File.join(@proc_root, name))
    end

    def load_average
      one, five, fifteen = read("loadavg").split.first(3).map(&:to_f)
      { "load_1" => one, "load_5" => five, "load_15" => fifteen }
    rescue SystemCallError
      {}
    end

    # Busy percentage across all cores since the previous sample, from the
    # aggregate "cpu" line: idle = idle + iowait, total = sum of the first
    # eight fields (guest time is already inside user/nice).
    def cpu(previous)
      lines = read("stat").lines
      fields = lines.first.split.drop(1).first(8).map(&:to_i)
      total = fields.sum
      idle = fields[3].to_i + fields[4].to_i
      result = { "cpu_total_jiffies" => total, "cpu_idle_jiffies" => idle,
                 "cores" => lines.count { |line| line.match?(/\Acpu\d+ /) } }
      prev_total = previous&.dig("cpu_total_jiffies")
      prev_idle = previous&.dig("cpu_idle_jiffies")
      if prev_total && prev_idle && total > prev_total
        busy = 1.0 - (idle - prev_idle).to_f / (total - prev_total)
        result["cpu_percent"] = (busy.clamp(0.0, 1.0) * 100).round(1)
      end
      result
    rescue SystemCallError
      {}
    end

    def memory
      values = read("meminfo").lines.to_h do |line|
        key, value = line.split(":", 2)
        [ key, value.to_i * 1024 ]
      end
      { "mem_total_bytes" => values["MemTotal"], "mem_available_bytes" => values["MemAvailable"] }.compact
    rescue SystemCallError
      {}
    end

    def disk
      result = BoundedCommand.run("df", "-B1", "-P", "/", timeout: 10)
      return {} unless result.ok
      _, total, used, available = result.stdout.lines.last.to_s.split
      { "disk_total_bytes" => total.to_i, "disk_used_bytes" => used.to_i, "disk_available_bytes" => available.to_i }
    end

  end
end
