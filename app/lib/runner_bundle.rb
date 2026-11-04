# The runner a VM should be running (#593). Runners ship inside cloud-init at
# birth, so without this a Rails deploy never reaches them. The bundle is the
# same deterministic, AST-checked, XZ-compressed tar RunnerUserData embeds;
# its digest changes exactly when the runner source does.
#
# A runner reports the bundle it runs (fact runner_bundle_sha256; absent on
# a runner still on its birth files). On each heartbeat, offer! queues one
# update_runner when that differs from the current bundle. The runner fetches
# the bytes by digest (Api::V1::HostRunner::RunnerBundlesController), checks,
# self-checks, swaps and restarts.
module RunnerBundle

  DIGEST = /\A[0-9a-f]{64}\z/
  # Between attempts for one enrollment, unless the last one is still open.
  RETRY_AFTER = 1.hour
  TOO_OLD = "command not allowed on this runner".freeze

  Bundle = Data.define(:bytes, :sha256)

  module_function

  def current
    source = File.read(RunnerUserData::RUNNER_SOURCE_PATH) + File.read(Rails.root.join("host-runner/backup_proxy.py"))
    key = Digest::SHA256.hexdigest(source)
    @current = nil unless @current_key == key
    @current_key = key
    @current ||= begin
      bytes = RunnerUserData.compressed_source_bundle
      Bundle.new(bytes:, sha256: Digest::SHA256.hexdigest(bytes))
    end
  end

  # Queues update_runner for this enrollment's runner when it runs another
  # bundle. Never raises: a heartbeat must not fail because of it.
  def offer!(enrollment, now: Time.current)
    return unless offer?(enrollment, now:)

    bundle = current
    RunnerCommand.enqueue!(enrollment:, kind: "update_runner",
      payload: { "sha256" => bundle.sha256, "bytes" => bundle.bytes.bytesize })
  rescue StandardError => e
    Rails.logger.warn("[runner_bundle] offer failed for #{enrollment.public_id}: #{e.class}: #{e.message}")
    nil
  end

  def offer?(enrollment, now: Time.current)
    return false unless enrollment.enrolled_at && enrollment.revoked_at.nil?

    placement = AgentPlacement.uncached { AgentPlacement.find_by(id: enrollment.agent_placement_id) }
    return false unless placement&.backend == "hetzner_cloud" && placement.state == "ready"

    reported = enrollment.last_facts.is_a?(Hash) ? enrollment.last_facts["runner_bundle_sha256"] : nil
    return false if reported == current.sha256

    last = enrollment.commands.where(kind: "update_runner").order(:id).last
    return true unless last
    return false unless last.terminal?
    # A runner from before update_runner can't take one: that needs an
    # operator, once, and asking again changes nothing.
    return false if last.state == "refused" && last.result&.dig("error").to_s.start_with?(TOO_OLD)

    last.created_at <= now - RETRY_AFTER
  end

end
