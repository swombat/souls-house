# The runner a VM should be running (#593). Runners ship inside cloud-init at
# birth, so without this a Rails deploy never reaches them. The bundle is the
# deterministic, AST-checked, XZ-compressed tar a new VM fetches at birth by
# the digest its user_data pins (RunnerBirthBundle, #779);
# its digest changes exactly when the runner source does.
#
# A runner reports the bundle it runs (fact runner_bundle_sha256; absent on
# a runner still on its birth files). On each heartbeat, offer! queues one
# update_runner when that differs from the current bundle. The runner fetches
# the bytes by digest (Api::V1::HostRunner::RunnerBundlesController), checks,
# self-checks, swaps and restarts.
#
# Two packages from the one tree (#426 3C). `birth` (the runner and the
# backup proxy) is what a new VM fetches at birth (#779) and what every runner, however old,
# can unpack. `full` adds the carry modules a migration's restore needs, and
# only a runner on this release's validator accepts it. So an old runner
# reaches `full` in two legs: birth first (two files, the bridge), then full
# once it reports birth's digest. Only a moving resident's pre-start
# placement is taken to `full`; every other runner counts either as current.
module RunnerBundle

  DIGEST = /\A[0-9a-f]{64}\z/
  # Between attempts for one enrollment, unless the last one is still open.
  RETRY_AFTER = 1.hour
  TOO_OLD = "command not allowed on this runner".freeze

  Bundle = Data.define(:bytes, :sha256)

  module_function

  # The birth package; also what an ordinary runner is kept on.
  def current
    package(full: false)
  end

  def full
    package(full: true)
  end

  # The package with this digest, if it is one of this release's two.
  def find(sha256)
    [ current, full ].find { |bundle| bundle.sha256 == sha256.to_s }
  end

  def package(full:)
    names = RunnerUserData::BIRTH_FILES + (full ? RunnerUserData::CARRY_FILES : [])
    key = Digest::SHA256.hexdigest(names.map { |name| File.read(Rails.root.join("host-runner", name)) }.join)
    @packages ||= {}
    cached = @packages[full]
    return cached[1] if cached && cached[0] == key

    bytes = RunnerUserData.compressed_source_bundle(full:)
    Bundle.new(bytes:, sha256: Digest::SHA256.hexdigest(bytes)).tap { |bundle| @packages[full] = [ key, bundle ] }
  end

  # Queues update_runner for this enrollment's runner when it runs another
  # bundle. Never raises: a heartbeat must not fail because of it.
  def offer!(enrollment, now: Time.current)
    bundle = offer(enrollment, now:)
    return unless bundle

    RunnerCommand.enqueue!(enrollment:, kind: "update_runner",
      payload: { "sha256" => bundle.sha256, "bytes" => bundle.bytes.bytesize })
  rescue StandardError => e
    Rails.logger.warn("[runner_bundle] offer failed for #{enrollment.public_id}: #{e.class}: #{e.message}")
    nil
  end

  def offer?(enrollment, now: Time.current)
    !offer(enrollment, now:).nil?
  end

  # The package this enrollment's runner should be sent now, or nil.
  def offer(enrollment, now: Time.current)
    return unless enrollment.enrolled_at && enrollment.revoked_at.nil?

    placement = AgentPlacement.uncached { AgentPlacement.find_by(id: enrollment.agent_placement_id) }
    return unless placement&.backend == "hetzner_cloud"

    target = target(placement, reported(enrollment))
    return unless target

    last = enrollment.commands.where(kind: "update_runner").order(:id).last
    return target unless last
    # One update at a time, whatever it was for.
    return unless last.terminal?
    # A runner from before update_runner can't take one: that needs an
    # operator, once, and asking again changes nothing.
    return if last.state == "refused" && last.result&.dig("error").to_s.start_with?(TOO_OLD)
    # A leg that installed another package (birth, on the way to full) is
    # progress: the next leg goes now. Failures, and an install of this same
    # package that the runner still doesn't report, wait out the hour. (An
    # answered command keeps its result, not its payload.)
    installed = last.result&.dig("result", "sha256")
    return target if last.state == "done" && installed.present? && installed != target.sha256

    target if last.created_at <= now - RETRY_AFTER
  end

  def reported(enrollment)
    enrollment.last_facts.is_a?(Hash) ? enrollment.last_facts["runner_bundle_sha256"] : nil
  end

  # A ready runner on either package is current. A moving resident's
  # placement, before its first start, goes to `full`: straight there from
  # birth's digest, otherwise birth first, since nothing else proves the
  # runner can unpack four files (a fresh birth reports no digest at all).
  def target(placement, reported)
    if carry_pending?(placement)
      return if reported == full.sha256
      reported == current.sha256 ? full : current
    elsif placement.state == "ready"
      current unless [ current.sha256, full.sha256 ].include?(reported)
    end
  end

  def carry_pending?(placement)
    placement.kind == "migration" && placement.state == "pending"
  end

  # Whether the runner reports running the full package: the only receipt
  # restore_carry waits for. An update_runner's success is not one.
  def full_running?(enrollment)
    reported(enrollment) == full.sha256
  end

end
