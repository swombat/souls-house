require "open3"
require "timeout"

module Agents
  # Runs one fixed Python script inside a resident's container on this host
  # and returns { ok:, stdout: }. The script is code the house ships; any
  # argument goes in as one argv value, never into the code. `seconds` bounds
  # the script inside the container; the house waits a little longer, then
  # kills the whole process group.
  module ResidentPython

    module_function

    def run(container_name, script, *args, seconds:)
      Open3.popen3("docker", "exec", container_name,
        "timeout", seconds.to_s, "python3", "-c", script, *args, pgroup: true) do |stdin, stdout, stderr, process|
        stdin.close
        output = Thread.new { stdout.read }
        errors = Thread.new { stderr.read }
        begin
          Timeout.timeout(seconds + 15) do
            { ok: process.value.success?, stdout: output.value }
          end
        ensure
          if process.alive?
            Process.kill("KILL", -process.pid)
            process.join
          end
          output.join
          errors.join
        end
      end
    end

  end
end
