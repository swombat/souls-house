require "test_helper"
require "support/app_oauth_test_helper"

# Issue #94, PR A: the racing spike cases, with real concurrent requests to
# /oauth/token on separate database connections. Non-transactional so the
# AppSession row lock is actually contended; interleavings are forced by
# holding that lock (or pausing a refresh inside it) and waiting until
# Postgres reports the other side blocked.
class Api::App::V1::OauthConcurrencyTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper

  self.use_transactional_tests = false

  setup do
    @user = users(:existing_user)
    @last_session_id = Session.maximum(:id).to_i
    @last_audit_id = AuditLog.maximum(:id).to_i
    @client = create_app_client
    @t1 = sign_in_device
    @app_session = AppSession.last
  end

  teardown do
    # A failed wait must not leave a paused refresh holding the row lock.
    @release&.push(true)
    @threads&.each { |thread| thread.join(5) }
    Doorkeeper.config.remove_instance_variable(:@after_successful_authorization) if Doorkeeper.config.instance_variable_defined?(:@after_successful_authorization)
    Doorkeeper::AccessToken.delete_all
    Doorkeeper::AccessGrant.delete_all
    AppSession.delete_all
    Doorkeeper::Application.delete_all
    Session.where("id > ?", @last_session_id).delete_all
    AuditLog.where("id > ?", @last_audit_id).delete_all
  end

  test "case b: concurrent refreshes with one refresh token leave exactly one live child" do
    threads = nil
    @app_session.with_lock do
      threads = 3.times.map { in_thread { refresh_status(@t1) } }
      wait_for_blocked(3)
    end
    statuses = threads.map(&:value)

    # All three fall inside Doorkeeper's grace window (t1 is unused-successor
    # deferred), but each later mint supersedes the one before it.
    assert_equal [ 200 ] * 3, statuses
    children = Doorkeeper::AccessToken.where(app_session_id: @app_session.id).where.not(id: row_for(@t1).id)
    assert_equal 3, children.count
    assert_equal 1, children.where(revoked_at: nil).count, "no two live children"
    assert_equal 2, live_tokens(@app_session).count, "the survivor plus t1 in its grace window"
    assert_nil @app_session.reload.revoked_at
  end

  test "case e: revoking the family while a refresh holds the lock still leaves nothing live" do
    minted = Queue.new
    release = Queue.new
    pause_after_mint(minted, release)

    refresher = in_thread { refresh_status(@t1) }
    minted.pop # the child exists, uncommitted, and the refresh holds the AppSession lock
    revoker = in_thread { AppSession.find(@app_session.id).revoke!(:user_revoked) }
    wait_for_blocked(1)
    release << true

    assert_equal 200, refresher.value
    revoker.value
    assert_equal 2, Doorkeeper::AccessToken.where(app_session_id: @app_session.id).count
    assert_empty live_tokens(@app_session), "the child committed first, so the revocation swept it"
    assert_equal "user_revoked", @app_session.reload.revocation_reason
  end

  test "case e: a refresh waiting on a revocation in progress mints nothing" do
    refresher = nil
    @app_session.with_lock do
      refresher = in_thread { refresh_status(@t1) }
      wait_for_blocked(1)
      @app_session.revoke!(:user_revoked)
    end

    assert_equal 400, refresher.value
    assert_equal 1, Doorkeeper::AccessToken.where(app_session_id: @app_session.id).count
    assert_empty live_tokens(@app_session)
    assert_equal "user_revoked", @app_session.reload.revocation_reason
  end

  test "case a/b: a refresh racing reuse detection cannot outlive the family" do
    t2 = refresh(@t1)
    use(t2) # t1 is now revoked by rotation

    minted = Queue.new
    release = Queue.new
    pause_after_mint(minted, release)

    legit = in_thread { refresh_status(t2) }
    minted.pop
    thief = in_thread { refresh_status(@t1) }
    wait_for_blocked(1)
    release << true

    assert_equal 200, legit.value
    assert_equal 400, thief.value
    assert_equal "reuse_detected", @app_session.reload.revocation_reason
    assert_empty live_tokens(@app_session)
  end

  private

  # A fresh integration session per thread, on its own connection.
  def in_thread(&block)
    test = self
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        test.open_session.instance_exec(test, &block)
      end
    end
    (@threads ||= []) << thread
    thread
  end

  def refresh_status(tokens)
    post "/oauth/token", params: { grant_type: "refresh_token", refresh_token: tokens["refresh_token"], client_id: "souls-house-android" }
    response.status
  end

  # Doorkeeper calls this hook inside TokensController#create's super, i.e.
  # after the child row is written and while the AppSession lock is held.
  def pause_after_mint(minted, release)
    @release = release
    hook = lambda do |controller, _context = nil|
      next unless controller.is_a?(Oauth::TokensController)

      minted << true
      release.pop
    end
    Doorkeeper.config.instance_variable_set(:@after_successful_authorization, hook)
  end

  def wait_for_blocked(count, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      # Uncached: the query cache would replay the first count forever.
      waiting = ActiveRecord::Base.uncached do
        ActiveRecord::Base.connection.select_value(
          "SELECT count(*) FROM pg_locks WHERE NOT granted AND locktype IN ('transactionid', 'tuple')"
        ).to_i
      end
      break if waiting >= count
      flunk "expected #{count} blocked transaction(s), saw #{waiting}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

end
