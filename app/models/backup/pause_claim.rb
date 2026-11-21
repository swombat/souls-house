module Backup
  # A backup's claim on a resident's pause (see the migration). One per
  # resident. AgentRestic writes it outside any transaction, before the
  # vault's lock, so it is committed before `docker pause`.
  class PauseClaim < ApplicationRecord
    self.table_name = "backup_pause_claims"

    belongs_to :agent

    def self.claim!(agent, container_id)
      token = SecureRandom.uuid
      where(agent_id: agent.id).delete_all
      create!(agent_id: agent.id, container_id:, token:)
      token
    end

    def self.release!(agent, token = nil)
      scope = where(agent_id: agent.id)
      scope = scope.where(token:) if token
      scope.delete_all
    end
  end
end
