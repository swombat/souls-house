class AgentHealthCheckJob < ApplicationJob

  require "net/http"

  queue_as :default

  def perform
    Agent.externally_hosted.find_each do |agent|
      next if intentionally_cold?(agent)

      restarts = restarts_since_last_probe(agent)
      apply_result(agent, healthy?(agent), restarts: restarts)
      ResidentUnreachableNotice.observe!(agent)
    end
  end

  private

  def intentionally_cold?(agent)
    return false if Agents::RemoteRuntime.remote?(agent)

    Agents::Config.cold_start? && Agents::Sandbox.new(agent).stopped?
  end

  def healthy?(agent)
    return Agents::RemoteRuntime.healthy?(agent) if Agents::RemoteRuntime.remote?(agent)

    uri = URI("#{Agents::Endpoint.url_for(agent).to_s.delete_suffix('/')}/health")
    response = Net::HTTP.get_response(uri)
    if (request = agent.github_resident_import) && request.sync_strategy == "standard"
      if response.code == "200" && response.body.to_s.bytesize <= 64.kilobytes
        begin
          body = JSON.parse(response.body)
          request.record_sync_health!(body.is_a?(Hash) ? body["home_sync"] : nil)
        rescue JSON::ParserError
          request.record_sync_health!(nil)
        end
      else
        request.record_sync_health!({ "state" => "unknown", "reason_code" => "runtime_unavailable" })
      end
    end
    response.code == "200"
  rescue StandardError
    false
  end

  # For a house resident, how many times Docker restarted its container since
  # the previous probe; nil when that can't be known (a VM resident, no
  # container, Docker not answering). The count is remembered on the row each
  # probe. A crash loop spends most of each minute up, so a probe can land in
  # the up-window and pass while the resident takes no turns (Claude, 28 Oct:
  # 537 restarts in nine hours); the growing count is what shows it. A smaller
  # count means the container was recreated, which is a fresh baseline.
  def restarts_since_last_probe(agent)
    return nil if Agents::RemoteRuntime.remote?(agent) || agent.container_name.blank?

    count = Agents::Sandbox.new(agent).restart_count
    return nil if count.nil?

    previous = agent.runtime_restart_count
    agent.runtime_restart_count = count
    previous && count > previous ? count - previous : 0
  end

  def apply_result(agent, healthy, restarts: nil)
    restarting = restarts.to_i.positive?
    if healthy && !restarting
      agent.update!(
        last_health_check_at: Time.current,
        health_state: "healthy",
        consecutive_health_failures: 0,
        health_failing_since: nil,
        health_failure_kind: nil,
        runtime: agent.offline? ? "external" : agent.runtime
      )
    else
      failures = agent.consecutive_health_failures + 1
      attrs = {
        last_health_check_at: Time.current,
        health_state: "unhealthy",
        consecutive_health_failures: failures,
        health_failing_since: agent.health_failing_since || Time.current,
        # "restarting" sticks for the rest of a failing run: a loop's probes
        # alternate between refused and answered, and the card should not flicker.
        health_failure_kind: restarting ? "restarting" : (agent.health_failure_kind || "unanswered")
      }
      attrs[:runtime] = "offline" if failures >= 6 && agent.external?
      agent.update!(attrs)
    end
  end

end
