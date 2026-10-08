class AgentHealthCheckJob < ApplicationJob

  require "net/http"

  queue_as :default

  def perform
    Agent.externally_hosted.find_each do |agent|
      next if intentionally_cold?(agent)

      apply_result(agent, healthy?(agent))
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

  def apply_result(agent, healthy)
    if healthy
      agent.update!(
        last_health_check_at: Time.current,
        health_state: "healthy",
        consecutive_health_failures: 0,
        runtime: agent.offline? ? "external" : agent.runtime
      )
    else
      failures = agent.consecutive_health_failures + 1
      attrs = {
        last_health_check_at: Time.current,
        health_state: "unhealthy",
        consecutive_health_failures: failures
      }
      attrs[:runtime] = "offline" if failures >= 6 && agent.external?
      agent.update!(attrs)
    end
  end

end
