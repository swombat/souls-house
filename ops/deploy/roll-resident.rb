# Executed inside the current web container, with parameters on stdin via ENV.
# stdout is private to the host worker. Only explicitly projected fields leave it.
require "open3"
require "json"

a = Agent.find(Integer(ENV.fetch("DEPLOY_RESIDENT_ID")))
target = ENV.fetch("DEPLOY_RESIDENT_IMAGE")
expected_version = ENV.fetch("DEPLOY_CHAOS_VERSION")

inspect_mounts = -> {
  out, _err, status = Open3.capture3("docker", "inspect", "--format", "{{json .Mounts}}", a.container_name)
  raise "Cannot inspect mounts" unless status.success?
  JSON.parse(out).map { |m| [m.fetch("Type"), m["Name"], m.fetch("Source"), m.fetch("Destination")] }.sort
}
idle = -> {
  next false if ResidentTurn.pending.where(agent: a).exists?
  next false if AgentRuntimeInteraction.where(agent: a, finished_at: nil)
    .where.not(execution_state: [nil, "queued"]).exists?
  _out, _err, status = Open3.capture3("docker", "exec", a.container_name, "pgrep", "-x", "chaos")
  status.exitstatus == 1
}

changed = false
result = nil
begin
  Agent.transaction do
    # Same gate as enqueue!/admit!. New requests wait for this short restart,
    # then enqueue normally; they are NOT cancelled by a visible paused flag.
    Agent.connection.execute("SET LOCAL lock_timeout = '5s'")
    # External Docker/HTTP work is idle-in-transaction from PostgreSQL's view.
    # Bound its hold even if the host loses its docker-exec connection.
    Agent.connection.execute("SET LOCAL idle_in_transaction_session_timeout = '90s'")
    Agent.connection.execute("SELECT pg_advisory_xact_lock(1936680308, 1)")
    gate_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    a.lock!
    if a.container_image == target
      result = {result: "current", id: a.id}
    elsif !idle.call
      result = {result: "busy", id: a.id}
    else
      before = inspect_mounts.call
      old = a.attributes.slice("active", "paused", "container_image")
      # The host retains this before starting; no private files or memory read.
      changed = true
      a.update!(active: true, paused: true, container_image: target)
      Agents::Sandbox.new(a).recreate!
      raise "Mounts changed" unless before == inspect_mounts.call
      out, _err, version_status = Open3.capture3("docker", "exec", a.container_name, "chaos", "--version")
      raise "Wrong Chaos version" unless version_status.success? && out.strip == expected_version
      receipt = ChaosTriggerClient.new(Agents::Endpoint.url_for(a), a.trigger_bearer_token)
        .turn_status(SecureRandom.uuid)
      raise "Ledger unavailable" unless receipt[:status] == 404 && receipt.dig(:body, "ledger_id").present?
      a.update!(active: old.fetch("active"), paused: old.fetch("paused"))
      result = {result: "healthy", id: a.id}
    end
    result[:gate_seconds] = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - gate_started).round(3)
  end
  puts result.to_json
rescue ActiveRecord::LockWaitTimeout
  raise if changed
  puts({result: "busy", id: a.id}.to_json)
rescue StandardError
  # DB rollback cannot roll back a container or runtime schema. Don't silently
  # boot an older binary against potentially migrated data.
  if changed
    actual, _err, inspected = Open3.capture3("docker", "inspect", "--format", "{{.Config.Image}}", a.container_name)
    attributes = {active: false, paused: true}
    attributes[:container_image] = actual.strip if inspected.success? && !actual.strip.empty?
    a.reload.update!(attributes)
  end
  raise
end
