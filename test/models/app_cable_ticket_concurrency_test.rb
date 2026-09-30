require "test_helper"

# #94 B, step 6: redemption against real contention, on separate connections.
# Non-transactional so the row locks are actually contended.
class AppCableTicketConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @user = User.create!(email_address: "tix#{SecureRandom.hex(4)}@example.com", password: "password123")
    @client = Doorkeeper::Application.create!(name: "App", uid: "tix-#{SecureRandom.hex(4)}", redirect_uri: "https://souls.house/cb", scopes: "chat", confidential: false)
    @app_session = AppSession.create!(user: @user, oauth_application: @client)
    @value, = AppCableTicket.issue!(@app_session)
    @release = Queue.new
    @ready = Queue.new
  end

  teardown do
    @release.push(true)
    @threads&.each { |thread| thread.join(5) }
    AppCableTicket.where(app_session: @app_session).delete_all
    @app_session.delete
    @client.delete
    @user.destroy
  end

  test "two simultaneous redemptions of one ticket: exactly one wins" do
    first = in_thread do
      AppCableTicket.transaction { AppCableTicket.redeem(@value).tap { @ready.push(true); @release.pop } }
    end
    @ready.pop(timeout: 5) or flunk "first redemption never ran"
    second = in_thread { AppCableTicket.redeem(@value) }
    wait_until { blocked_count >= 1 }
    @release.push(true)

    assert_equal [ @app_session.id, nil ], [ first.value&.id, second.value&.id ]
  end

  test "a redemption racing a revocation waits for it and is refused" do
    in_thread do
      AppSession.transaction { AppSession.find(@app_session.id).revoke!(:user_revoked); @ready.push(true); @release.pop }
    end
    @ready.pop(timeout: 5) or flunk "revocation never ran"
    redeemer = in_thread { AppCableTicket.redeem(@value) }
    wait_until { blocked_count >= 1 }
    @release.push(true)

    assert_nil redeemer.value
    assert_nil AppCableTicket.sole.consumed_at
  end

  private

  def in_thread(&block)
    thread = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
    (@threads ||= []) << thread
    thread
  end

  def blocked_count
    ActiveRecord::Base.uncached do
      ActiveRecord::Base.connection.select_value(
        "SELECT count(*) FROM pg_locks WHERE NOT granted AND locktype IN ('transactionid', 'tuple')"
      ).to_i
    end
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "timed out waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

end
