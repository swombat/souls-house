# frozen_string_literal: true

module LocalInstance
  # Own a separate process group for cleanup, but lend it the controlling
  # terminal while it runs. A new pgroup alone is a background job (SIGTTIN).
  class Command

    def self.run(argv)
      new.run(argv)
    end

    def run(argv)
      @terminal = terminal_if_foreground
      @original_group = Process.getpgrp
      @child = Process.spawn(*argv, pgroup: true)
      previous_handlers = %w[INT TERM HUP].to_h do |signal|
        [ signal, Signal.trap(signal) { signal_group(signal) } ]
      end
      foreground(@child)
      signal_group("CONT")

      loop do
        _, status = Process.waitpid2(@child, Process::WUNTRACED)
        if status.stopped?
          # A read can race the initial foreground transfer. Resume that read,
          # but propagate deliberate job suspension to the supervising shell.
          unless [ Signal.list.fetch("TTIN"), Signal.list.fetch("TTOU") ].include?(status.stopsig)
            foreground(@original_group)
            Process.kill("STOP", Process.pid)
          end
          foreground(@child)
          signal_group("CONT")
        else
          @reaped = true
          return status.exitstatus || 128 + status.termsig
        end
      end
    ensure
      foreground(@original_group) if @terminal && @original_group
      signal_group("TERM") if @child
      Process.waitpid(@child) if @child && !@reaped
      previous_handlers&.each { |signal, handler| Signal.trap(signal, handler) }
    end

    private

    def terminal_if_foreground
      return unless STDIN.tty?
      require_relative "instance_terminal"
      STDIN if Terminal.tcgetpgrp(STDIN.fileno) == Process.getpgrp
    end

    def foreground(group)
      return unless @terminal
      previous = Signal.trap("TTOU", "IGNORE")
      result = Terminal.tcsetpgrp(@terminal.fileno, group)
      raise SystemCallError.new("Cannot transfer the controlling terminal", Fiddle.last_error) unless result.zero?
    ensure
      Signal.trap("TTOU", previous) if previous
    end

    def signal_group(signal)
      Process.kill(signal, -@child) if @child
    rescue Errno::ESRCH
      # The group has already exited; never look for a replacement by port/PID.
    end

  end
end
