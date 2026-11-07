module Billing
  # A session lock spans several committed transactions. The same key conflicts
  # with SubscriptionSync's transaction lock; always acquire it before any rows.
  class CheckoutLock

    def self.synchronize(agent)
      ApplicationRecord.connection_pool.with_connection do |connection|
        raise NotReady, "Checkout must start outside a database transaction." if connection.transaction_open?

        connection.uncached do
          key = "#{SubscriptionSync::LOCK_NAMESPACE}, #{Integer(agent.id)}"
          acquired = false
          begin
            begin
              acquired = connection.select_value("SELECT pg_try_advisory_lock(#{key})")
            rescue StandardError
              # The database may have acquired the lock before transport failed.
              connection.pool.remove(connection)
              connection.disconnect!
              raise
            end
            raise NotReady, "Billing for #{agent.name} is busy. Please try again in a moment." unless acquired

            yield
          ensure
            release(connection, key) if acquired
          end
        end
      end
    end

    def self.release(connection, key)
      failed = false
      begin
        failed = !connection.select_value("SELECT pg_advisory_unlock(#{key})")
      rescue StandardError
        failed = true
      end
      return unless failed

      # Never return a potentially locked session to the pool.
      connection.pool.remove(connection)
      connection.disconnect!
      raise NotReady, "Billing's database connection was interrupted. Please try again." unless $!
    end
    private_class_method :release

  end
end
