require "json"

module Agents
  # The resident's own view of its Tailscale node, read from inside its
  # container with soulshouse-tailnet. The node lives there (userspace
  # tailscaled, state on the resident's volume), so this is the only place
  # that knows whether it is waiting for a sign-in, and which link to use.
  class Tailnet

    class Unavailable < StandardError; end

    # Said on the panel after "<name>'s node isn't reachable right now: ",
    # when the resident's own server runs a runner from before the tailnet
    # command (runners ship at birth). The node itself still works from
    # inside, so the owner gets the route that does.
    RUNNER_TOO_OLD_DETAIL = "this resident runs on its own server, whose runner can't read Tailscale yet. " \
                            "Ask the resident to run `soulshouse-tailnet up` and send you the sign-in link.".freeze

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

    def run(action, *flags)
      result = Agents::RemoteRuntime.remote?(agent) ? remote_exec(action) : local_exec(action, *flags)
      report = parse(result[:stdout])
      unless result[:ok] && report
        detail = result[:stderr].to_s.strip.lines.last.to_s.strip.presence || "soulshouse-tailnet #{action} failed"
        raise Unavailable, detail.delete_prefix("soulshouse-tailnet: ")
      end
      report.slice(*REPORT_KEYS).merge("container" => "running")
    rescue Agents::Sandbox::SandboxError, Agents::Resources::OwnershipError => e
      raise Unavailable, e.message
    end

    def local_exec(action, *flags)
      sandbox.exec_as_agent("soulshouse-tailnet", action, *flags, timeout_seconds: 45)
    end

    # A resident on its own server: the same command, run by its runner
    # (#593). The runner returns stdout when it succeeds and stderr when not.
    def remote_exec(action)
      answer = Agents::RemoteRuntime.tailnet!(agent, action:)
      ok = answer.is_a?(Hash) && answer["ok"] == true
      output = answer.is_a?(Hash) ? answer["output"].to_s : ""
      { ok:, stdout: ok ? output : "", stderr: ok ? "" : output }
    rescue Agents::RemoteRuntime::RunnerTooOld
      raise Unavailable, RUNNER_TOO_OLD_DETAIL
    rescue Agents::RemoteRuntime::Unavailable => e
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
