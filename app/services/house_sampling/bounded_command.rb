require "open3"

module HouseSampling
  # Runs a fixed argv with a real deadline. The child gets its own process
  # group; if it is still running at the deadline the group is sent TERM,
  # then KILL after a short grace, and the child is reaped. Only that group
  # is signalled, never anything matched by name.
  #
  # Timeout.timeout around Open3.capture2 does not do this: it unwinds into
  # Open3's wait for the child, so a hung child holds the caller past the
  # deadline.
  module BoundedCommand

    Result = Data.define(:ok, :stdout, :timed_out)

    GRACE = 2

    module_function

    def run(*argv, timeout:)
      Open3.popen3(*argv, pgroup: true) do |stdin, stdout, stderr, process|
        stdin.close
        output = Thread.new { stdout.read }
        errors = Thread.new { stderr.read }
        finished = process.join(timeout)
        unless finished
          signal_group(process, "TERM")
          signal_group(process, "KILL") unless process.join(GRACE)
          process.join(GRACE)
        end
        out = output.join(GRACE) ? output.value : ""
        errors.join(GRACE)
        Result.new(ok: finished ? process.value.success? : false, stdout: out.to_s, timed_out: !finished)
      end
    rescue SystemCallError
      Result.new(ok: false, stdout: "", timed_out: false)
    end

    def signal_group(process, signal)
      Process.kill(signal, -process.pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

  end
end
