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
  # The job calls it only while it holds the lease, when no backup and no
  # other thinning can be running.
  class VmThinning

    class Failed < StandardError; end

    TIMEOUT_SECONDS = 30 * 60
    # How long a mark is believed after its last renewal. One command cannot
    # run this long, so past it the job that held the mark is not running one.
    CLAIM_SECONDS = TIMEOUT_SECONDS + 5 * 60

    def self.running?(agent, now: Time.current)
      started = agent.backup_thinning_started_at
      started.present? && started > now - CLAIM_SECONDS
    end

    def self.abandoned?(agent, now: Time.current)
      agent.backup_thinning_started_at.present? && !running?(agent, now:)
    end
    Result = Struct.new(:kept, :removed, :oldest_at, keyword_init: true)

    def initialize(run: nil)
      @run = run
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
        "--keep-monthly", agent.backup_keep_monthly.to_s,
        "--prune")
      # What is left is read back, never taken from forget's own report.
      kept = snapshots(agent)
      raise Failed, "No snapshot is left after thinning" if kept.empty? && before.any?

      Result.new(kept: kept.size, removed: [ before.size - kept.size, 0 ].max,
        oldest_at: kept.filter_map { |snapshot| Time.zone.parse(snapshot["time"].to_s) rescue nil }.min)
    end

    # After an interrupted thinning: remove its container, confirm it is gone,
    # then clear the repository's locks. The caller holds the lease.
    def recover(agent)
      @renew = nil
      remove_container!(agent) unless @run
      run(agent, "unlock", "--remove-all")
      true
    end

    private

    # One name per resident, so a container a dead job left behind can be
    # found and removed, and two thinnings of one repository cannot coexist.
    def container_name(agent) = "vm-backup-thin-#{agent.uuid}"

    # Locks are removed only once no thinning container can still be writing.
    def remove_container!(agent)
      name = container_name(agent)
      system("docker", "rm", "--force", name, out: File::NULL, err: File::NULL)
      _out, _err, status = Open3.capture3("docker", "container", "inspect", name)
      raise Failed, "The thinning container could not be removed" if status.success?
    end

    def snapshots(agent)
      list = JSON.parse(run(agent, "snapshots", "--json"))
      raise Failed, "Unreadable snapshot list" unless list.is_a?(Array)

      list
    rescue JSON::ParserError
      raise Failed, "Unreadable snapshot list", cause: nil
    end

    def run(agent, *args)
      @renew&.call
      return @run.call(agent, *args) if @run
      # No production credential lookup or Docker operation in ordinary tests.
      raise Failed, "Live VM backup thinning is disabled in tests" if Rails.env.test?

      name = container_name(agent)
      argv = [ "timeout", "--kill-after=30", TIMEOUT_SECONDS.to_s,
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
      system("docker", "rm", "--force", name, out: File::NULL, err: File::NULL)
      raise Failed, "restic #{args.first} failed: #{err.to_s.squish.last(500).presence || "exit #{status.exitstatus}"}"
    end

  end
end
