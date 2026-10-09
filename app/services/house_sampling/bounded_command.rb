module HouseSampling
  # Runs a fixed argv with one deadline covering both the process and its
  # output pipes. The child starts its own process group. If the pipes are
  # still open or the leader is still running at the deadline, the group gets
  # TERM, then KILL after a short grace, whether or not the leader has
  # already exited, so a descendant that ignores TERM or keeps the pipes open
  # can't outlive it.
  #
  # The leader is reaped only after the group has been signalled. Until then
  # it is at worst a zombie, so its pid (the group id) can't be reused, and a
  # group signal can only reach processes this call started. Nothing is
  # signalled by name.
  #
  # Output is read with IO.select on non-blocking pipes, so there are no
  # reader threads to leak. stderr is drained and discarded.
  module BoundedCommand

    Result = Data.define(:ok, :stdout, :timed_out)

    GRACE = 2
    POLL = 0.02

    module_function

    def run(*argv, timeout:)
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      pipes = [ out_r, err_r ]
      begin
        pid = Process.spawn(*argv, in: File::NULL, out: out_w, err: err_w, pgroup: true)
      rescue SystemCallError
        return Result.new(ok: false, stdout: "", timed_out: false)
      ensure
        out_w.close
        err_w.close
      end

      stdout = +""
      deadline = clock + timeout
      status = drain(pipes, stdout, deadline) ? reap(pid, deadline) : nil
      timed_out = status.nil?
      if timed_out
        signal_group(pid, "TERM")
        drain(pipes, stdout, clock + GRACE)
        signal_group(pid, "KILL")
        drain(pipes, stdout, clock + GRACE)
        status = reap(pid, clock + GRACE) || reap_now(pid)
      end
      Result.new(ok: !timed_out && status&.success? == true, stdout:, timed_out:)
    ensure
      pipes&.each { |io| io.close unless io.closed? }
    end

    # Reads until every pipe reaches end of file (true) or the deadline
    # passes (false). A pipe reaching end of file is closed.
    def drain(pipes, buffer, deadline)
      loop do
        open = pipes.reject(&:closed?)
        return true if open.empty?
        remaining = deadline - clock
        return false if remaining <= 0
        ready, = IO.select(open, nil, nil, remaining)
        Array(ready).each do |io|
          chunk = io.read_nonblock(65_536, exception: false)
          if chunk.nil?
            io.close
          elsif chunk != :wait_readable && io.equal?(pipes.first)
            buffer << chunk
          end
        end
      end
    end

    # The leader's exit status, or nil if it is still running at the deadline.
    def reap(pid, deadline)
      loop do
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        return status if status
        return nil if clock >= deadline
        sleep POLL
      end
    rescue Errno::ECHILD
      nil
    end

    def reap_now(pid)
      Process.waitpid2(pid).last
    rescue Errno::ECHILD
      nil
    end

    def signal_group(pid, signal)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

  end
end
