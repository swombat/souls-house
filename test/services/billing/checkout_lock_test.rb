require "test_helper"

class Billing::CheckoutLockTest < ActiveSupport::TestCase

  class Connection

    attr_reader :removed, :disconnected, :queries
    attr_accessor :acquire, :release

    def initialize(acquire: true, release: true)
      @acquire, @release, @queries = acquire, release, []
    end

    def transaction_open? = false
    def uncached = yield
    def pool = self
    def remove(connection) = @removed = connection
    def disconnect! = @disconnected = true
    def with_connection = yield self

    def select_value(query)
      @queries << query
      answer = query.include?("pg_try_advisory_lock") ? acquire : release
      raise answer if answer.is_a?(Exception)

      answer
    end

  end

  def lock(connection, &block)
    agent = agents(:research_assistant)
    ApplicationRecord.stub(:connection_pool, connection) do
      Billing::CheckoutLock.synchronize(agent, &block)
    end
  end

  test "normal release is performed after a failed operation" do
    connection = Connection.new
    assert_raises(ArgumentError) { lock(connection) { raise ArgumentError, "operation failed" } }
    assert_match(/pg_advisory_unlock/, connection.queries.last)
    assert_nil connection.disconnected
  end

  test "busy acquisition neither enters nor unlocks somebody else's lock" do
    connection = Connection.new(acquire: false)
    assert_raises(Billing::NotReady) { lock(connection) { flunk "busy lock entered" } }
    assert_equal 1, connection.queries.size
    assert_nil connection.disconnected
  end

  test "uncertain acquisition closes and discards the possibly locked session" do
    connection = Connection.new(acquire: ActiveRecord::ConnectionNotEstablished.new("lost answer"))
    assert_raises(ActiveRecord::ConnectionNotEstablished) { lock(connection) { flunk "uncertain lock entered" } }
    assert_same connection, connection.removed
    assert connection.disconnected
  end

  test "a false or failed unlock closes and discards the session" do
    [ false, ActiveRecord::ConnectionNotEstablished.new("unlock failed") ].each do |answer|
      connection = Connection.new(release: answer)
      assert_raises(Billing::NotReady) { lock(connection) { true } }
      assert_same connection, connection.removed
      assert connection.disconnected
    end
  end

end
