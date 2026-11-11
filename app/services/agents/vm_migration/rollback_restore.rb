module Agents
  class VmMigration
    # The restic arguments that restore one role of a rollback snapshot into
    # its fresh volume (#426 3C checkpoint 3). Pure: no IO.
    #
    # --verify is not optional. A shape digest and `restic check` prove the
    # snapshot and the repository; only --verify reads back what restic wrote
    # into the destination and compares it with the snapshot (Mira, #838
    # design read). A restore without it is refused here, not left to habit.
    module RollbackRestore
      SNAPSHOT = /\A[0-9a-f]{64}\z/

      def self.path(role)
        role = role.to_sym
        raise ArgumentError, "unknown role #{role}" unless RollbackPlan::ROLES.include?(role)

        "/rollback/#{role}"
      end

      # The fresh volume is mounted (read-write) at path(role) in the tool
      # container; nothing else is writable there.
      def self.args(snapshot_id, role)
        raise ArgumentError, "snapshot id must be a full restic id" unless SNAPSHOT.match?(snapshot_id.to_s)

        [ "restore", "#{snapshot_id}:#{path(role)}", "--target", path(role), "--verify" ]
      end

      def self.verified_args?(args)
        args.first == "restore" && args.include?("--verify")
      end
    end
  end
end
