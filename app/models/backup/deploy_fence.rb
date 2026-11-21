module Backup
  # Raised by a deploy (ops/deploy/worker.py) while it waits for backups and
  # switches releases, so that no house backup pauses a resident the release
  # switch could then strand (Mira frozen 04:08-06:50Z, 21 Nov 2026). A fence
  # expires by itself, so a deploy that dies holding one delays backups but
  # can't stop them. See the migration.
  class DeployFence < ApplicationRecord

    self.table_name = "backup_deploy_fences"

    # Shared by DeployFence.raise! and PauseClaim.claim!.
    LOCK_KEY = 2_026_112_104

    def self.serialized
      transaction(requires_new: true) do
        # Bounded, so a wait on a lock its own caller holds fails rather
        # than hangs a backup or a deploy.
        connection.execute("SET LOCAL lock_timeout = '30s'")
        connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_KEY})")
        yield
      end
    end

    def self.up?(now = Time.current) = where("expires_at > ?", now).exists?

    def self.raise!(deploy_id, ttl:)
      serialized do
        where(deploy_id:).delete_all
        now = Time.current
        create!(deploy_id:, raised_at: now, expires_at: now + ttl)
      end
    end

    def self.lower!(deploy_id)
      where(deploy_id:).delete_all
      where("expires_at <= ?", Time.current).delete_all
    end

  end
end
