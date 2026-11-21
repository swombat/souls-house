require "test_helper"
require "support/comms_send_helpers"

# Real concurrency for the send grant (WhatsApp spec §5): threads with their
# own database connections and committed rows, coordinated so the
# interleaving that used to revive or keep a grant is forced. Every path
# that sets or clears can_send takes the connection's row lock first, then
# the access row, and reads both fresh; these tests fail without that. Each
# thread's result is asserted explicitly (assert_thread_ok /
# assert_thread_raised): an exception is never taken for success. Not
# transactional; the rows made here are removed in teardown.
class CommsSendGrantConcurrencyTest < ActiveSupport::TestCase

  include CommsSendHelpers

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
    @connection, @access, _chat = committed_whatsapp_fixture(agent: @agent, owner: @owner)
  end

  teardown do
    remove_committed_whatsapp_fixture(@connection)
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
      fresh_access.change_send_grant!(true, actor: @owner)
    ensure
      granted.count_down
    end

    assert_not assert_thread_ok(disable).enabled?
    assert_match "Enable this resident's access first", assert_thread_raised(grant, AgentServiceAccess::SendGrantRefused).message
    @access.reload
    assert_not @access.enabled?
    assert_not @access.can_send?, "a disable must never leave can_send behind"

    # And re-enabling read does not revive anything.
    @agent.set_service_access!(@connection.reload, enabled: true, actor: @owner)
    assert_not @access.reload.can_send?
  end

  test "disable racing a grant that holds its locks withdraws the grant and records it" do
    holding = Concurrent::CountDownLatch.new(1)
    release = Concurrent::CountDownLatch.new(1)

    grant = in_thread do
      ActiveRecord::Base.transaction do
        access = fresh_access.change_send_grant!(true, actor: @owner)
        holding.count_down
        release.wait(WAIT)
        access
      end
    end
    assert holding.wait(WAIT)
    agent, connection = fresh_agent, fresh_connection
    disable = in_thread { agent.set_service_access!(connection, enabled: false, actor: @owner) }
    sleep 0.3
    release.count_down

    assert assert_thread_ok(grant).can_send?
    assert_not assert_thread_ok(disable).can_send?
    @access.reload
    assert_not @access.enabled?
    assert_not @access.can_send?
    assert_equal [ %w[granted granted], %w[withdrawn access_disabled] ], events
  end

  test "owner change committed while a grant was in flight refuses the grant" do
    assert_authority_change_refuses_grant(/owner/) { |connection| connection.update!(connected_by_user: @other_user) }
  end

  test "disconnect committed while a grant was in flight refuses the grant" do
    assert_authority_change_refuses_grant(/owner|Reconnect/) { |connection| connection.disconnect!(revoke_provider: false) }
  end

  test "owner change after a grant took its locks withdraws the grant and records it" do
    assert_change_after_grant_withdraws("owner_changed") { |connection| connection.update!(connected_by_user: @other_user) }
  end

  test "disconnect after a grant took its locks withdraws the grant and records it" do
    assert_change_after_grant_withdraws("disconnected") { |connection| connection.disconnect!(revoke_provider: false) }
  end

  private

  # The authority change runs first and holds its transaction open while
  # the owner's grant (loaded before the change) runs. The grant must wait
  # for it, see the change, and refuse.
  def assert_authority_change_refuses_grant(message, &change)
    access = fresh_access
    access.service_connection # loaded before the change, as a request would have
    changed = Concurrent::CountDownLatch.new(1)
    release = Concurrent::CountDownLatch.new(1)

    changer = in_thread do
      ActiveRecord::Base.transaction do
        change.call(fresh_connection)
        changed.count_down
        release.wait(0.5)
        :changed
      end
    end
    assert changed.wait(WAIT)
    grant = in_thread { access.change_send_grant!(true, actor: @owner) }
    sleep 0.2
    release.count_down

    assert_equal :changed, assert_thread_ok(changer)
    assert_match message, assert_thread_raised(grant, AgentServiceAccess::SendGrantRefused).message
    assert_not @access.reload.can_send?
    assert_empty events.select { |action, _| action == "granted" }
  end

  # The grant holds both locks first; the change waits for it, then
  # withdraws what it granted.
  def assert_change_after_grant_withdraws(reason, &change)
    holding = Concurrent::CountDownLatch.new(1)
    release = Concurrent::CountDownLatch.new(1)

    grant = in_thread do
      ActiveRecord::Base.transaction do
        access = fresh_access.change_send_grant!(true, actor: @owner)
        holding.count_down
        release.wait(WAIT)
        access
      end
    end
    assert holding.wait(WAIT)
    connection = fresh_connection
    changer = in_thread { change.call(connection) && :changed }
    sleep 0.3
    release.count_down

    assert assert_thread_ok(grant).can_send?
    assert_equal :changed, assert_thread_ok(changer)
    assert_not @access.reload.can_send?
    assert_equal [ %w[granted granted], [ "withdrawn", reason ] ], events
  end

  def fresh_connection = ServiceConnection.find(@connection.id)
  def fresh_agent = Agent.find(@agent.id)
  def fresh_access = AgentServiceAccess.find(@access.id)

  def events
    CommsSendGrantEvent.where(service_connection_id: @connection.id).order(:id).pluck(:action, :reason)
  end

end
