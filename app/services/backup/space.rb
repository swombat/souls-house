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
    # A VM writes through the house (VmRepository), which needs some bound on
    # what one repository can take between thinnings. Half as much again as
    # the space: room for a backup to land before older history is removed.
    WRITE_CEILING_FACTOR = 1.5

    module_function

    def bytes_for(agent)
      size = ResidentEntitlement.where(agent_id: agent.id, state: Billing::Tier::IN_FORCE_STATES)
        .order(:id).last&.tier_record&.size
      GB_BY_SIZE.fetch(size, DEFAULT_GB).gigabytes
    end

    def write_ceiling_bytes(agent)
      override = ENV["VM_BACKUP_BUDGET_BYTES"].presence
      override ? Integer(override, 10) : (bytes_for(agent) * WRITE_CEILING_FACTOR).to_i
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
