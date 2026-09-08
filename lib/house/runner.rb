# frozen_string_literal: true

require "open3"

module House
  # Runs one read-only script on the deploy host over SSH. Its own object,
  # rather than an inline `ssh` call in House::Doctor, so doctor's checks can
  # be tested against a stub instead of a real host.
  class Runner
    def initialize(user:, host:, port:)
      @user = user
      @host = host
      @port = port
    end

    # Executes +script+ on the remote host. Returns [output, ok?]: output
    # combines stdout and stderr (an SSH connection failure and the script's
    # own output land in the same stream), ok? is the ssh process's exit
    # status.
    def ssh(script)
      argv = [
        "ssh", "-p", @port.to_s,
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "#{@user}@#{@host}",
        script
      ]
      output, status = Open3.capture2e(*argv)
      [output, status.success?]
    end
  end
end
