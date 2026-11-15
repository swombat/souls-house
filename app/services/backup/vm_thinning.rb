require "open3"

module Backup
  # Thins a VM resident's backup history to its keep rules (7 daily, 4 weekly,
  # 12 monthly unless the resident's own numbers differ), the rules house
  # residents have always had (AgentResticJob#prune!).
  #
  # A VM cannot do this itself: its restic reaches the repository through the
  # house (VmRepository), which lets it add objects and remove its own locks
  # and nothing else. So the house runs restic against the repository
  # directly, with its own storage credentials, after a backup has been
  # verified. Until this existed a VM's history only grew, and the resident
  # would one day have met its repository budget and stopped being backed up.
  #
  # A backup and a thinning never run together, and the house decides that,
  # not restic's lock: VmThinningJob marks the resident
  # (backup_thinning_started_at) under the agent lock, where VmResident.issue!
  # also looks, so a backup is not issued while history is being thinned and
  # thinning does not start while a backup is held.
  #
  # The mark is a lease. `call` asks its holder to renew it before every
  # restic command (`renew:`), and a command is killed after TIMEOUT_SECONDS,
  # which is shorter than the lease, so a thinning that is still running
  # always holds a fresh mark. If the renewal refuses, the thinning stops
  # before the next command.
  #
  # A thinning that is killed can leave restic's exclusive lock behind, which
  # would fail every later backup. `recover` removes the thinning container,
  # confirms it is gone, and only then removes every lock in the repository.
  # "Gone" needs a positive answer: Docker listed every container with that
  # name, stopped ones included, and the list did not hold it. An error, a
  # timeout or an unreachable daemon is unknown, and unknown keeps the mark,
  # so the resident's backups stay paused until a later recovery succeeds.
  # Each recovery step is bounded and renews the lease first, so a job that
  # lost the lease stops before the unlock.
  class VmThinning

    class Failed < StandardError; end

    # Raised to the error tracker by the sweeper when a resident's backups
    # have stayed paused past ALERT_AFTER.
    class Stalled < StandardError; end

    TIMEOUT_SECONDS = 30 * 60
    # `timeout` sends TERM at the limit and KILL this much later.
    KILL_GRACE_SECONDS = 30
    # Recovery's own steps are short ones.
    RECOVERY_TIMEOUT_SECONDS = 5 * 60
    DOCKER_TIMEOUT_SECONDS = 60
    # How long a mark is believed after its last renewal. One command cannot
    # run this long, kill grace included, so past it the job that held the
    # mark is not running one.
    CLAIM_SECONDS = TIMEOUT_SECONDS + KILL_GRACE_SECONDS + 5 * 60
    # Measured from the first unresolved interruption
    # (backup_thinning_interrupted_at), never from the lease, which moves.
    ALERT_AFTER = 3.hours

    def self.running?(agent, now: Time.current)
      started = agent.backup_thinning_started_at
      started.present? && started > now - CLAIM_SECONDS
    end

    def self.abandoned?(agent, now: Time.current)
      agent.backup_thinning_started_at.present? && !running?(agent, now:)
    end
    Result = Struct.new(:kept, :removed, :oldest_at, keyword_init: true)

    # `run` stands in for restic and `docker` for the Docker client in tests.
    def initialize(run: nil, docker: nil)
      @run = run
      @docker = docker
    end

    def call(agent, renew: nil)
      @renew = renew
      raise Failed, "Thinning requires a VM placement" unless Agents::RemoteRuntime.remote?(agent)
      raise Failed, "Invalid resident identity" unless VmRepository::UUID.match?(agent.uuid.to_s)
      raise Failed, "Backup password is missing" if agent.restic_password.blank?

      before = snapshots(agent)
      run(agent, "forget",
        "--keep-daily", agent.backup_keep_daily.to_s,
        "--keep-weekly", agent.backup_keep_weekly.to_s,
        "--keep-monthly", agent.backup_keep_monthly.to_s)
      # A prune of its own, every time: forget --prune prunes only when it
      # forgot something, and a failed backup's partial data needs removing
      # even on a night when no backup aged out.
      run(agent, "prune")
      # What is left is read back, never taken from forget's own report.
      raise Failed, "No snapshot is left after thinning" if snapshots(agent).empty? && before.any?

      # Then the resident's backup space: thin further if it is over, and
      # record what the repository holds.
      history = Fit.new(agent, run: ->(*args) { run(agent, *args) }).call
      Result.new(kept: history["snapshots"], removed: [ before.size - history["snapshots"], 0 ].max,
        oldest_at: history["oldest_at"])
    rescue Fit::Failed => error
      raise Failed, error.message, cause: nil
    end

    # After an interrupted thinning: remove its container, confirm it is gone,
    # then clear the repository's locks. The caller holds the lease.
    def recover(agent, renew: nil)
      @renew = renew
      remove_container!(agent) if @docker || !@run
      run(agent, "unlock", "--remove-all", timeout: RECOVERY_TIMEOUT_SECONDS)
      true
    end

    private

    # One name per resident, so a container a dead job left behind can be
    # found and removed, and two thinnings of one repository cannot coexist.
    def container_name(agent) = "vm-backup-thin-#{agent.uuid}"

    # Locks are removed only once no thinning container can still be writing.
    def remove_container!(agent)
      name = container_name(agent)
      @renew&.call
      docker("rm", "--force", name)
      @renew&.call
      # The filter matches substrings, so the exact name is compared here.
      listed, answered = docker("ps", "--all", "--filter", "name=#{name}", "--format", "{{.Names}}")
      return if answered && listed.to_s.lines.map(&:strip).exclude?(name)

      raise Failed, "The thinning container could not be confirmed gone"
    end

    # [ stdout, whether Docker answered successfully ], within a time limit.
    def docker(*args)
      return @docker.call(*args) if @docker
      raise Failed, "Live Docker operations are disabled in tests" if Rails.env.test?

      out, _err, status = Open3.capture3("timeout", "--kill-after=10", DOCKER_TIMEOUT_SECONDS.to_s, "docker", *args)
      [ out, status.success? ]
    end

    def snapshots(agent)
      list = JSON.parse(run(agent, "snapshots", "--json"))
      raise Failed, "Unreadable snapshot list" unless list.is_a?(Array)

      list
    rescue JSON::ParserError
      raise Failed, "Unreadable snapshot list", cause: nil
    end

    def run(agent, *args, timeout: TIMEOUT_SECONDS)
      @renew&.call
      return @run.call(agent, *args) if @run
      # No production credential lookup or Docker operation in ordinary tests.
      raise Failed, "Live VM backup thinning is disabled in tests" if Rails.env.test?

      name = container_name(agent)
      argv = [ "timeout", "--kill-after=#{KILL_GRACE_SECONDS}", timeout.to_s,
        "docker", "run", "--rm", "--name", name,
        "-e", "AWS_ACCESS_KEY_ID=#{AgentRestic.aws_value(:access_key_id)}",
        "-e", "AWS_SECRET_ACCESS_KEY=#{AgentRestic.aws_value(:secret_access_key)}",
        "-e", "AWS_DEFAULT_REGION=#{AgentRestic.region}",
        "-e", "RESTIC_PASSWORD=#{agent.restic_password}",
        "-e", "RESTIC_REPOSITORY=#{AgentRestic.repository_url(agent)}",
        VmSnapshotVerifier::IMAGE, "--no-cache", *args ]
      out, err, status = Open3.capture3(*argv)
      return out if status.success?

      # Killing the client does not stop a container the daemon still runs.
      docker("rm", "--force", name)
      raise Failed, "restic #{args.first} failed: #{err.to_s.squish.last(500).presence || "exit #{status.exitstatus}"}"
    end

  end
end
