module Backup
  # A backup's claim on a resident's pause (see the migration). One per
  # resident. AgentRestic writes it outside any transaction, before the
  # vault's lock, so it is committed before `docker pause`.
  class PauseClaim < ApplicationRecord

    self.table_name = "backup_pause_claims"

    belongs_to :agent

    # Refused while a deploy's fence is up (DeployFence): the backup is
    # busy-retried later instead of pausing a resident the release switch
    # could strand. The fence check and the claim share one lock with the
    # fence's raise, so there is no gap between them.
    #
    # Committed on a connection of its own when the caller is inside a
    # transaction (Mira, #1096): a savepoint in someone else's transaction
    # would let Docker pause before the claim commits, and a dead worker
    # would roll the claim back with it.
    def self.claim!(agent, container_id)
      independently do
        DeployFence.serialized do
          raise AgentRestic::ResidentBusy, "A deploy is switching releases" if DeployFence.up?

          token = SecureRandom.uuid
          where(agent_id: agent.id).delete_all
          create!(agent_id: agent.id, container_id:, token:, touched_at: Time.current)
          token
        end
      end
    end

    def self.independently(&block)
      return yield unless connection.transaction_open?

      Thread.new { connection_pool.with_connection(&block) }.value
    end

    def self.touch!(token) = where(token:).update_all(touched_at: Time.current)

    # Keeps a claim's touched_at fresh while its backup holds the pause, on
    # its own thread and connection. A worker that is killed stops touching,
    # so its claim goes stale within minutes however long a live backup
    # takes (ops/deploy/backup-in-flight.rb).
    class Heartbeat

      INTERVAL = 60 # seconds

      def self.start(token, interval: INTERVAL) = new(token, interval).tap(&:start)

      def initialize(token, interval)
        @token, @interval, @stop = token, interval, Thread::Queue.new
      end

      def start
        @thread = Thread.new do
          until @stop.pop(timeout: @interval)
            begin
              Rails.application.executor.wrap { PauseClaim.touch!(@token) }
            rescue StandardError => error
              Rails.logger.error("[Backup::PauseClaim::Heartbeat] #{error.class}")
            end
          end
        end
      end

      def stop
        @stop << true
        @thread&.join(5)
      end

    end

    def self.release!(agent, token = nil)
      scope = where(agent_id: agent.id)
      scope = scope.where(token:) if token
      scope.delete_all
    end

  end
end
