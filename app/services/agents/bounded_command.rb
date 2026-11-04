require "open3"

module Agents
  # Open3.capture3 with a deadline (a monotonic clock reading). The command
  # runs in its own process group. The deadline covers the leader's exit AND
  # the draining of stdout/stderr: a leader that exits while a backgrounded
  # child still holds the pipes open is not finished. When the deadline
  # passes first, the whole group is killed (whether or not the leader is
  # still alive), reaped, and TimedOut is raised, so a blocked docker call
  # cannot outlive the caller's deadline. A nil deadline is plain
  # Open3.capture3, so callers without one behave as before.
  module BoundedCommand

    class TimedOut < StandardError; end

    # After the group is killed the pipes should close at once; this only
    # bounds a reader whose writer escaped the group (setsid).
    REAP_GRACE = 1

    module_function

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def left(deadline) = [ deadline - now, 0 ].max

    def capture3(*args, deadline: nil)
      return Open3.capture3(*args) unless deadline

      raise TimedOut if left(deadline) <= 0

      Open3.popen3(*args, pgroup: true) do |stdin, stdout, stderr, process|
        group = process.pid
        stdin.close
        out = reader(stdout)
        err = reader(stderr)
        finished = false
        begin
          raise TimedOut unless process.join(left(deadline))
          raise TimedOut unless out.join(left(deadline)) && err.join(left(deadline))

          finished = true
          [ out.value, err.value, process.value ]
        ensure
          unless finished
            kill_group(group)
            process.join
            [ out, err ].each { |thread| thread.join(REAP_GRACE) || thread.kill }
          end
        end
      end
    end

    def reader(io)
      Thread.new { io.read }.tap { |thread| thread.report_on_exception = false }
    end

    # The group id stays valid while any member lives, even after the leader
    # has exited; ESRCH means nothing of the group is left.
    def kill_group(group)
      Process.kill("KILL", -group)
    rescue Errno::ESRCH
      nil
    end

  end
end
