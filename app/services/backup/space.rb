module Backup
  # How much backup storage a resident comes with (Daniel, eRyZBY 2026-11-15:
  # "the limit of backups should be per resident, not per account ... each
  # resident comes with a certain backup capacity", enough for at least one
  # full backup). A little more than the size's disk (Billing::Tier's Boat
  # machines: 51 GB for Small and Medium, 111 GB for Large), so one full
  # backup always fits.
  #
  # The space is never a reason to refuse a backup. A resident over it has
  # older history thinned (Backup::Fit); the newest backup is always kept.
  module Space

    GB_BY_SIZE = { "small" => 60, "medium" => 60, "large" => 120 }.freeze
    DEFAULT_GB = 60
    # A VM writes through the house (VmRepository), which bounds what one
    # repository can take. The bound has to let the next backup land before
    # older history is thinned: the history kept (up to the space) plus one
    # whole new backup that shares nothing with it (at most the disk, which
    # is under the space), plus a quarter of the space for data a failed
    # backup left behind and packs a prune has not yet rewritten.
    WRITE_CEILING_FACTOR = 2.25

    module_function

    def bytes_for(agent)
      size = ResidentEntitlement.where(agent_id: agent.id, state: Billing::Tier::IN_FORCE_STATES)
        .order(:id).last&.tier_record&.size
      GB_BY_SIZE.fetch(size, DEFAULT_GB).gigabytes
    end

    # VM_BACKUP_BUDGET_BYTES can raise the ceiling, never lower it: the old
    # flat 20 GB setting must not survive as a way to refuse backups.
    def write_ceiling_bytes(agent)
      computed = (bytes_for(agent) * WRITE_CEILING_FACTOR).to_i
      override = ENV["VM_BACKUP_BUDGET_BYTES"].presence
      override ? [ Integer(override, 10), computed ].max : computed
    end

    # What the repository occupies in storage: every object under its prefix,
    # the same count VmRepository's write ceiling uses. nil where there is no
    # object store to ask (a local repository, tests).
    def physical_bytes(agent)
      return nil if Rails.env.test? || LocalRepository.enabled?

      VmRepository.new(agent:, deadline_seconds: 120).stored_bytes
    rescue VmRepository::Refused => error
      Rails.logger.warn("[backup] physical size unavailable agent_id=#{agent.id}: #{error.code}")
      nil
    end

    # For the hosting tab: what the repository held when last read, or nil
    # before the first reading.
    def summary(agent)
      history = agent.backup_history
      return nil if history.blank? || history["read_at"].blank?

      { snapshots: history["snapshots"], oldest_at: history["oldest_at"], stored_bytes: history["stored_bytes"],
        space_bytes: bytes_for(agent), thinned_to_fit: history["thinned_to_fit"] == true,
        over_space: history["over_space"] == true, read_at: history["read_at"] }
    end

  end
end
