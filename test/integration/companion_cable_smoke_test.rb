require "test_helper"

# Opt-in cross-repository gate, real Puma + Action Cable + Go client. Uses only
# this checkout's test database and synthetic credentials, under bin/rails test's
# ordinary lock. No production token, host access, or paid model is involved.
if ENV["COMPANION_GO_REPO"].present?
  require "puma"
  require "tmpdir"

  class CompanionCableSmokeTest < ActiveSupport::TestCase

    self.use_transactional_tests = false
    parallelize(workers: 1)

    test "Go client survives real Cable pings and consumes mutation inputs" do
      agent = agents(:research_assistant)
      grant = CompanionEnrollmentGrant.create!(account: agent.account, minting_agent: agent,
        created_by_user: users(:user_1), name: "Synthetic Cable integration",
        device_request_id: SecureRandom.hex(12),
        policy: { "residents" => [ { "id" => agent.obfuscated_id,
          "volumes" => [ { "volume" => "fixture-volume", "access" => "write" } ], "execute" => true } ] },
        expires_at: 1.hour.from_now)
      device, credential = CompanionEnrollmentGrant.enroll!(grant.issue_token!(agent), grant.device_request_id)
      server = Puma::Server.new(Rails.application)
      server.add_tcp_listener("127.0.0.1", 0)
      server.run
      # Test adapter implements actual subscription delivery in-process.
      Dir.mktmpdir("companion-cable-") do |dir|
        fixture = File.join(dir, "fixture.json")
        File.write(fixture, { URL: "http://127.0.0.1:#{server.connected_ports.first}",
          DeviceID: device.obfuscated_id, Credential: credential, Policy: grant.policy }.to_json, perm: 0600)
        env = ENV.to_h.slice("HOME", "PATH", "GOPATH", "GOCACHE")
        env["COMPANION_RAILS_FIXTURE"] = fixture
        output = File.open(File.join(dir, "probe.log"), "w", 0600)
        pid = Process.spawn(env, ENV.fetch("COMPANION_GO_BIN", "go"), "test", "./internal/client",
          "-run", "^TestRealRailsActionCable$", "-count=1", chdir: ENV.fetch("COMPANION_GO_REPO"),
          unsetenv_others: true, out: output, err: output)
        wait_until { device.reload.connection_epoch.present? }
        # More than two real 3-second Cable heartbeat intervals before dispatch.
        sleep 7
        operation = CompanionOperation.start!(device: device.reload, agent: agent, kind: "drives", arguments: {})
        assert operation.dispatch!
        wait_until { operation.reload.state == "completed" }
        assert_equal '{"fixture":"real-rails"}', operation.take_body!.first
        [
          [ "write", { volume: "fixture-volume", path: "fixture" }, "input-fixture" ],
          [ "execute", {}, '{"argv":["true"],"cwd":"/tmp"}' ]
        ].each do |kind, arguments, input|
          operation = CompanionOperation.start!(device: device.reload, agent: agent, kind: kind,
            arguments: arguments.stringify_keys.merge("input_size" => input.bytesize))
          assert_not operation.dispatch!, "missing input dispatched"
          operation.attach_input!(input)
          assert operation.dispatch!
          wait_until { operation.reload.state == "completed" }
          assert_equal '{"fixture":"real-rails"}', operation.take_body!.first
          assert_nil operation.reload.input
        end
        _, status = Process.wait2(pid)
        pid = nil
        output.close
        assert status.success?, File.read(File.join(dir, "probe.log"))
      ensure
        Process.kill("TERM", pid) if pid
        Process.wait(pid) if pid
        output&.close
      end
    ensure
      server&.stop(true)
      CompanionOperation.where(companion_device: device).destroy_all if device
      CompanionCableTicket.where(companion_device: device).delete_all if device
      device&.destroy!
      grant&.destroy!
    end

    private

    def wait_until
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      until yield
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC), :<, deadline, "real Cable probe timed out"
        sleep 0.05
      end
    end

  end
end
