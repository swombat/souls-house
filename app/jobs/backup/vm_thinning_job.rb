module Backup
  # Runs after a VM resident's backup is verified (VmResident.settle!), and
  # from the sweeper when a thinning was left interrupted.
  #
  # It marks the resident for as long as it runs. VmResident.issue! refuses a
  # backup while any mark stands, and this job does not start while a backup
  # is held; both decide under the agent lock, so the two never overlap.
  #
  # The mark is a lease (Lease below). The job renews it before every restic
  # command, and each command is bounded by less than the lease lasts, so a
  # job that is still working never loses it to age. A job that finds the
  # lease is no longer its own stops and touches nothing: it does not
  # recover, unlock or clear a mark that belongs to someone else.
  #
  # The mark is cleared in two cases only: the thinning finished, or the
  # repository was recovered (VmThinning#recover) while the lease was still
  # this job's. Any other ending, a restic failure, an unexpected error or an
  # interrupted process whose recovery did not complete, leaves the mark
  # standing. No backup is issued then, and the sweeper sends the resident
  # back here once the mark is old enough to be taken over.
  class VmThinningJob < ApplicationJob

    # The resident's thinning mark, held by one job. The mark's timestamp is
    # the token: renewing moves it forward only if it is still the value this
    # job last wrote.
    class Lease

      class Lost < StandardError; end

      attr_reader :took_over

      def initialize(agent, token, took_over:)
        @agent_id = agent.id
        @token = token
        @took_over = took_over
      end

      def renew!
        now = Time.current.change(usec: 0)
        swap!(now)
        @token = now
      end

      def release! = swap!(nil)

      private

      def swap!(value)
        rows = Agent.where(id: @agent_id, backup_thinning_started_at: @token).update_all(backup_thinning_started_at: value)
        raise Lost, "The thinning mark for agent #{@agent_id} belongs to another job" if rows.zero?
      end

    end

    queue_as :default

    def perform(agent_id, thinning: VmThinning.new)
      return unless Agents::Config.backups_enabled?

      agent = Agent.find_by(id: agent_id)
      return unless agent && Agents::RemoteRuntime.remote?(agent)
      return if agent.account.disabled?

      lease = claim!(agent) or return
      finished = false
      begin
        recover!(agent, lease, thinning) if lease.took_over
        result = thinning.call(agent, renew: lease.method(:renew!))
        finished = true
        Rails.logger.info("[vm_backup] thinned agent_id=#{agent.id} kept=#{result.kept} removed=#{result.removed}")
        result
      rescue Lease::Lost => error
        Rails.logger.warn("[vm_backup] thinning stopped agent_id=#{agent.id}: #{error.message}")
        nil
      rescue StandardError => error
        record_failure(agent, error)
        Rails.error.report(error, handled: true) unless error.is_a?(VmThinning::Failed)
        nil
      ensure
        settle!(agent, lease, thinning, finished:)
      end
    end

    private

    # Under the agent lock: nil when a backup is held or another thinning is
    # running; otherwise the lease, and whether it replaced an abandoned one.
    def claim!(agent)
      agent.with_lock do
        next nil if VmResident.held?(agent) || VmThinning.running?(agent)

        took_over = VmThinning.abandoned?(agent)
        token = Time.current.change(usec: 0)
        agent.update_columns(backup_thinning_started_at: token)
        Lease.new(agent, token, took_over:)
      end
    end

    # Renewing first is the ownership check: recovery removes a container and
    # every lock in the repository, so it runs only for the lease's holder.
    def recover!(agent, lease, thinning)
      lease.renew!
      thinning.recover(agent)
    end

    # Runs on every way out, including an interrupted process. The mark is
    # released only after a finished thinning or a recovery that completed.
    def settle!(agent, lease, thinning, finished:)
      recover!(agent, lease, thinning) unless finished
      lease.release!
    rescue Lease::Lost
      nil
    rescue StandardError => error
      record_failure(agent, error)
    end

    def record_failure(agent, error)
      Rails.logger.error("[vm_backup] thinning failed agent_id=#{agent.id}: #{error.message}")
      snapshot = agent.agent_backup_snapshots.where(ok: true).order(taken_at: :desc).first
      snapshot&.update!(stderr_tail: [ snapshot.stderr_tail.presence, "Prune failed: #{error.message}" ].compact.join("\n").last(4000))
    end

  end
end
