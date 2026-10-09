require "test_helper"

# Real concurrency for the send grant (spec §5): threads with their own
# database connections and committed rows, coordinated so the interleaving
# that used to revive or keep a grant is forced. Every path that sets or
# clears can_send takes the connection's row lock first, then the access
# row, and reads both fresh; these tests fail without that. Not
# transactional; the rows made here are removed in teardown.
class CommsSendGrantConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  # Lets a test pause a thread inside AgentServiceAccess#save!, after the row
  # was loaded and before it is written. Only threads that set the hook stop.
  module PauseBeforeSave

    def save!(*args, **options, &block)
      Thread.current[:comms_grant_test_before_access_save]&.call
      super
    end

  end
  AgentServiceAccess.prepend(PauseBeforeSave)

  WAIT = 5

  setup do
    @owner = users(:user_1)
    @other_user = users(:regular_user)
    @agent = agents(:research_assistant)
    attributes = Services::Definition.fetch("whatsapp").adapter.connection_attributes(credentials: {}, user: @owner)
    @connection = @agent.account.service_connections.create!(
      connected_by_user: @owner, provider: "whatsapp", management_scope: "personal", status: "connected",
      label: attributes[:label], credential_kind: attributes[:credential_kind],
      credential_fingerprint: attributes[:credential_fingerprint], credential_metadata: attributes[:credential_metadata],
      credential_payload_hash: attributes[:credential_payload]
    )
    @access = @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
  end

  teardown do
    CommsSendGrantEvent.where(service_connection_id: @connection.id).delete_all
    AgentServiceAccess.where(service_connection_id: @connection.id).delete_all
    ServiceConnection.where(id: @connection.id).delete_all
  end

  test "disable that loaded the row before a concurrent grant committed still ends with no grant" do
    loaded = Concurrent::CountDownLatch.new(1)
    granted = Concurrent::CountDownLatch.new(1)

    disable = in_thread do
      Thread.current[:comms_grant_test_before_access_save] = lambda do
        loaded.count_down
        # Without the lock the grant commits here; with it, the grant waits
        # on the connection row until this commits, so this times out.
        granted.wait(0.5)
      end
      fresh_agent.set_service_access!(fresh_connection, enabled: false, actor: @owner)
    end
    grant = in_thread do
      loaded.wait(WAIT)
      access = fresh_access
      access.change_send_grant!(true, actor: @owner)
    ensure
      granted.count_down
    end

    disable.join(WAIT)
    grant.join(WAIT)
    @access.reload
    assert_not @access.enabled?
    assert_not @access.can_send?, "a disable must never leave can_send behind"
    assert grant.value.is_a?(AgentServiceAccess::SendGrantRefused), grant.value.inspect

    # And re-enabling read does not revive anything.
    @agent.set_service_access!(@connection.reload, enabled: true, actor: @owner)
    assert_not @access.reload.can_send?
  end

  test "disable racing a grant that holds its locks withdraws the grant and records it" do
    holding = Concurrent::CountDownLatch.new(1)
    release = Concurrent::CountDownLatch.new(1)

    grant = in_thread do
      ActiveRecord::Base.transaction do
        fresh_access.change_send_grant!(true, actor: @owner)
        holding.count_down
        release.wait(WAIT)
      end
    end
    holding.wait(WAIT)
    agent, connection = fresh_agent, fresh_connection
    disable = in_thread { agent.set_service_access!(connection, enabled: false, actor: @other_user) }
    sleep 0.3
    release.count_down

    grant.join(WAIT)
    disable.join(WAIT)
    assert_nothing_raised { disable.value }
    @access.reload
    assert_not @access.enabled?
    assert_not @access.can_send?
    assert_equal [ %w[granted granted], %w[withdrawn access_disabled] ], events
  end

  test "owner change committed while a grant was in flight refuses the grant" do
    assert_authority_change_refuses_grant { |connection| connection.update!(connected_by_user: @other_user) }
  end

  test "disconnect committed while a grant was in flight refuses the grant" do
    assert_authority_change_refuses_grant { |connection| connection.disconnect!(revoke_provider: false) }
  end

  test "owner change after a grant took its locks withdraws the grant and records it" do
    holding = Concurrent::CountDownLatch.new(1)
    release = Concurrent::CountDownLatch.new(1)

    grant = in_thread do
      ActiveRecord::Base.transaction do
        fresh_access.change_send_grant!(true, actor: @owner)
        holding.count_down
        release.wait(WAIT)
      end
    end
    holding.wait(WAIT)
    connection = fresh_connection
    change = in_thread { connection.update!(connected_by_user: @other_user) }
    sleep 0.3
    release.count_down

    grant.join(WAIT)
    change.join(WAIT)
    assert_nothing_raised { change.value }
    assert_not @access.reload.can_send?
    assert_equal [ %w[granted granted], %w[withdrawn owner_changed] ], events
  end

  private

  # The authority change runs first and holds its transaction open while
  # the owner's grant (loaded before the change) runs. The grant must wait
  # for it, see the change, and refuse.
  def assert_authority_change_refuses_grant(&change)
    access = fresh_access
    access.service_connection # loaded before the change, as a request would have
    changed = Concurrent::CountDownLatch.new(1)
    release = Concurrent::CountDownLatch.new(1)

    changer = in_thread do
      ActiveRecord::Base.transaction do
        change.call(fresh_connection)
        changed.count_down
        release.wait(0.5)
      end
    end
    changed.wait(WAIT)
    grant = in_thread { access.change_send_grant!(true, actor: @owner) }
    sleep 0.2
    release.count_down

    changer.join(WAIT)
    grant.join(WAIT)
    assert_nothing_raised { changer.value }
    assert grant.value.is_a?(AgentServiceAccess::SendGrantRefused), grant.value.inspect
    assert_not @access.reload.can_send?
    assert_empty events.select { |action, _| action == "granted" }
  end

  def in_thread(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        block.call
      rescue StandardError => error
        error
      end
    end
  end

  def fresh_connection = ServiceConnection.find(@connection.id)
  def fresh_agent = Agent.find(@agent.id)
  def fresh_access = AgentServiceAccess.find(@access.id)

  def events
    CommsSendGrantEvent.where(service_connection_id: @connection.id).order(:id).pluck(:action, :reason)
  end

end
