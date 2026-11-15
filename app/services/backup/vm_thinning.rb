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
  # restic's own repository lock keeps this apart from a backup: forget
  # --prune takes the exclusive lock and fails if the VM holds one, and the VM
  # sees the house's lock through the same repository. `unlock` first removes
  # only locks restic itself judges stale.
  class VmThinning

    class Failed < StandardError; end

    TIMEOUT_SECONDS = 30 * 60
    Result = Struct.new(:kept, :removed, :oldest_at, keyword_init: true)

    def initialize(run: nil)
      @run = run
    end

    def call(agent)
      raise Failed, "Thinning requires a VM placement" unless Agents::RemoteRuntime.remote?(agent)
      raise Failed, "Invalid resident identity" unless VmRepository::UUID.match?(agent.uuid.to_s)
      raise Failed, "Backup password is missing" if agent.restic_password.blank?

      run(agent, "unlock")
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

    private

    def snapshots(agent)
      list = JSON.parse(run(agent, "snapshots", "--json"))
      raise Failed, "Unreadable snapshot list" unless list.is_a?(Array)

      list
    rescue JSON::ParserError
      raise Failed, "Unreadable snapshot list", cause: nil
    end

    def run(agent, *args)
      return @run.call(agent, *args) if @run
      # No production credential lookup or Docker operation in ordinary tests.
      raise Failed, "Live VM backup thinning is disabled in tests" if Rails.env.test?

      name = "vm-backup-thin-#{SecureRandom.hex(12)}"
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
