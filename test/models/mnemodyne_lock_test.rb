require "test_helper"

class MnemodyneLockTest < ActiveSupport::TestCase

  class LockProbe < Mnemodyne::Record

    self.table_name = "agents"

  end

  test "a contended graph style lock times out and restores the connection setting" do
    # Reuse a committed fixture row solely to exercise the graph base's real
    # PostgreSQL lock policy; no synthetic row needs committing outside this test.
    record_class = Class.new(Mnemodyne::Record) { self.table_name = "agents" }
    record = record_class.find(agents(:research_assistant).id)
    # Transactional fixtures pin the default pool across threads. A separate
    # pool to this exact worker database is required for genuine PG contention.
    LockProbe.establish_connection(ActiveRecord::Base.connection_db_config.configuration_hash)
    outcome = Queue.new
    thread = nil
    record.with_lock do
      thread = Thread.new do
        LockProbe.connection_pool.with_connection do |connection|
          before = connection.select_value("SHOW lock_timeout")
          begin
            LockProbe.find(record.id).with_lock { outcome << :unexpected_lock }
          rescue ActiveRecord::LockWaitTimeout
            outcome << :timed_out
          end
          outcome << [ before, connection.select_value("SHOW lock_timeout") ]
        end
      end
      assert thread.join(5), "Contending writer did not respect its lock budget"
    end
    assert_equal :timed_out, outcome.pop
    before, after = outcome.pop
    assert_equal before, after
  ensure
    thread&.kill if thread&.alive?
    LockProbe.remove_connection
  end

end
