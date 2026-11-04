require "open3"

module Agents
  # Open3.capture3 with a deadline (a monotonic clock reading). The command
  # runs in its own process group; when the deadline passes first, the whole
  # group is killed and reaped and TimedOut is raised, so a blocked docker
  # call cannot outlive the caller's deadline. A nil deadline is plain
  # Open3.capture3, so callers without one behave as before.
  module BoundedCommand

    class TimedOut < StandardError; end

    module_function

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def capture3(*args, deadline: nil)
      return Open3.capture3(*args) unless deadline

      left = deadline - now
      raise TimedOut if left <= 0

      Open3.popen3(*args, pgroup: true) do |stdin, stdout, stderr, process|
        stdin.close
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }
        begin
          raise TimedOut unless process.join(left)

          [ out.value, err.value, process.value ]
        ensure
          if process.alive?
            begin
              Process.kill("KILL", -process.pid)
            rescue Errno::ESRCH
              nil
            end
            process.join
          end
          out.join
          err.join
        end
      end
    end

  end
end
