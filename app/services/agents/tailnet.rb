require "json"

module Agents
  # The resident's own view of its Tailscale node, read from inside its
  # container with soulshouse-tailnet. The node lives there (userspace
  # tailscaled, state on the resident's volume), so this is the only place
  # that knows whether it is waiting for a sign-in, and which link to use.
  class Tailnet

    class Unavailable < StandardError; end

    REPORT_KEYS = %w[granted daemon backend_state auth_url node addresses hosts pubkey admin_url].freeze

    attr_reader :agent

    def initialize(agent, sandbox: Agents::Sandbox.new(agent))
      @agent = agent
      @sandbox = sandbox
    end

    # Read-only: what the node reports now.
    def status
      run("status", "--json")
    end

    # Starts the daemon, asks for a login link when the node isn't joined, and
    # refreshes the resident's SSH aliases when it is. Idempotent.
    def up
      run("up", "--json")
    end

    private

    attr_reader :sandbox

    def run(*args)
      result = sandbox.exec_as_agent("soulshouse-tailnet", *args, timeout_seconds: 45)
      report = parse(result[:stdout])
      unless result[:ok] && report
        detail = result[:stderr].to_s.strip.lines.last.to_s.strip.presence || "soulshouse-tailnet #{args.first} failed"
        raise Unavailable, detail.delete_prefix("soulshouse-tailnet: ")
      end
      report.slice(*REPORT_KEYS).merge("container" => "running")
    rescue Agents::Sandbox::SandboxError => e
      raise Unavailable, e.message
    end

    def parse(stdout)
      value = JSON.parse(stdout.to_s)
      value.is_a?(Hash) ? value : nil
    rescue JSON::ParserError
      nil
    end

  end
end
