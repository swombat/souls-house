require "test_helper"
require "webmock/minitest"

# Real simultaneous posts on separate connections. Non-transactional so the
# row lock on the integration is actually contended.
class XPosterConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @agent = agents(:research_assistant)
    XIntegration.where(account_id: @agent.account_id).destroy_all
    @integration = XIntegration.create!(
      account: @agent.account, enabled: true, x_username: "househandle", client_id: "own-cid", client_secret: "own-secret",
      access_token: "live-token", refresh_token: "refresh-1", token_expires_at: 2.hours.from_now
    )
    @ids = (1..100).to_a
    @id_lock = Mutex.new
    @stub = stub_request(:post, "https://api.x.com/2/tweets").to_return do
      sleep 0.05
      id = @id_lock.synchronize { @ids.shift }
      { status: 201, body: { data: { id: id.to_s } }.to_json, headers: { "Content-Type" => "application/json" } }
    end
  end

  teardown do
    @integration&.tweet_logs&.delete_all
    @integration&.destroy
  end

  test "simultaneous posts with one key send exactly once" do
    outcomes = race(5) { post!("Same post", key: "one-key") }

    assert_equal [ "posted" ], outcomes.uniq.compact - [ "pending" ]
    assert_requested @stub, times: 1
    assert_equal 1, @integration.tweet_logs.count
  end

  test "switching posting off stops posts that have not reserved yet" do
    @integration.update!(enabled: false)

    outcomes = race(3) { |i| post!("Post #{i}", key: "off-#{i}") }

    assert_equal [ "posting_disabled" ], outcomes.uniq
    assert_not_requested @stub
  end

  test "a resolver waits for a send in progress and then sees its outcome; the post is sent once" do
    sending = Queue.new
    release = Queue.new
    WebMock.reset!
    stub = stub_request(:post, "https://api.x.com/2/tweets").to_return do
      sending << true
      release.pop(timeout: 20)
      { status: 201, body: { data: { id: "777" } }.to_json, headers: { "Content-Type" => "application/json" } }
    end

    sender = Thread.new { ActiveRecord::Base.connection_pool.with_connection { post!("In flight", key: "in-flight") } }
    assert sending.pop(timeout: 20), "the send never started"

    log = @integration.tweet_logs.find_by!(idempotency_key: "in-flight")
    resolver_result = Queue.new
    resolver = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TweetLog.find(log.id).tap { |row| row.define_singleton_method(:resolvable?) { |**| status.in?(%w[pending outcome_unknown]) } }
          .resolve!(resolution: "not_posted", by: @agent)
        resolver_result << :resolved
      rescue ArgumentError => e
        resolver_result << e.message
      end
    end

    sleep 0.5
    assert resolver.alive?, "the resolver should be waiting on the post's lock"
    release << true
    sender.join(20)
    resolver.join(20)

    assert_equal "posted", log.reload.status
    assert_equal "777", log.tweet_id
    assert_match(/can be resolved/, resolver_result.pop(timeout: 1).to_s)
    assert_requested stub, times: 1
  end

  test "removing the app waits for a send in progress, and a later send uses nothing of the old app" do
    sending = Queue.new
    release = Queue.new
    WebMock.reset!
    stub = stub_request(:post, "https://api.x.com/2/tweets").to_return do
      sending << true
      release.pop(timeout: 20)
      { status: 201, body: { data: { id: "778" } }.to_json, headers: { "Content-Type" => "application/json" } }
    end

    sender = Thread.new { ActiveRecord::Base.connection_pool.with_connection { post!("In flight", key: "in-flight") } }
    assert sending.pop(timeout: 20), "the send never started"

    removed = Queue.new
    remover = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        XIntegration.find(@integration.id).remove_own_app!
        removed << :removed
      end
    end

    sleep 0.5
    assert remover.alive?, "removing the app should wait for the send in progress"
    assert removed.empty?
    release << true
    sender.join(20)
    remover.join(20)

    assert_equal :removed, removed.pop(timeout: 1)
    assert_equal "posted", @integration.tweet_logs.find_by!(idempotency_key: "in-flight").status
    assert_requested stub, times: 1

    @integration.reload
    assert_not @integration.connected?
    assert_not @integration.own_app?
    assert_equal "not_connected", post!("After removal", key: "after")
    assert_requested stub, times: 1
  end

  test "a send in progress does not hold up another post's reservation" do
    sending = Queue.new
    release = Queue.new
    WebMock.reset!
    ids = Queue.new
    %w[801 802].each { |id| ids << id }
    stub = stub_request(:post, "https://api.x.com/2/tweets").to_return do
      sending << true
      release.pop(timeout: 20)
      { status: 201, body: { data: { id: ids.pop } }.to_json, headers: { "Content-Type" => "application/json" } }
    end

    first = Thread.new { ActiveRecord::Base.connection_pool.with_connection { post!("First", key: "first") } }
    assert sending.pop(timeout: 20), "the first send never started"
    second = Thread.new { ActiveRecord::Base.connection_pool.with_connection { post!("Second", key: "second") } }

    assert sending.pop(timeout: 20), "the second post should reserve and send while the first is in flight"
    2.times { release << true }
    first.join(20)
    second.join(20)

    assert_equal %w[posted posted], @integration.tweet_logs.order(:id).pluck(:status)
    assert_requested stub, times: 2
  end

  private

  def post!(text, key:)
    XPoster.new(agent: Agent.find(@agent.id)).post!(text:, idempotency_key: key).log.status
  rescue XPoster::Refused => e
    e.code
  end

  def race(count)
    gate = Queue.new
    results = Queue.new
    threads = count.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          results << yield(i)
        end
      end
    end
    count.times { gate << true }
    threads.each { |thread| thread.join(20) }
    Array.new(results.size) { results.pop }
  end

end
