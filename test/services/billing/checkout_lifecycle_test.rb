require "test_helper"
require "support/fake_stripe"
require "timeout"

class Billing::CheckoutLifecycleTest < ActiveSupport::TestCase

  include FakeStripe::Helpers

  # A savepoint cannot prove that Stripe's intent is durably published.
  self.use_transactional_tests = false

  setup do
    @agent = agents(:research_assistant)
    @original_agent = @agent.attributes.slice("name", "runtime", "model_id")
    @original_entitlement = ResidentEntitlement.find_by(agent: @agent)&.attributes
    @agent.update_columns(runtime: "inline", model_id: "anthropic/claude-opus-4")
    @stripe = FakeStripe.new
    @customer = BillingCustomer.create!(account: @agent.account, stripe_customer_id: "cus_checkout_lifecycle")
    @code = BillingCode.create!(code: "LIFECYCLE-#{SecureRandom.hex(6)}", effect: "at_cost",
      created_by: users(:site_admin_user))
    @grant = BillingCode.redeem!(code: @code.code, account: @agent.account, by: users(:user_1))
  end

  teardown do
    if @agent
      BillingCheckoutAttempt.where(agent_id: @agent.id).delete_all
      entitlements = ResidentEntitlement.where(agent_id: @agent.id)
      if @original_entitlement
        entitlements.update_all(@original_entitlement.except("id"))
      else
        entitlements.delete_all
      end
      ResidentSubscription.where(agent_id: @agent.id).delete_all
      @agent.update_columns(@original_agent) if @original_agent
    end
    @grant&.delete
    @code&.delete
    @customer&.delete
  end

  test "the complete intent is committed on another connection before Stripe create" do
    with_checkout_create do |create, params, opts|
      observed = worker do
        pin = attempts.sole
        [ pin.attributes, ApplicationRecord.connection.select_value("SELECT pg_backend_pid()").to_i ]
      end
      attributes, observer_pid = result(observed)
      assert_not_equal ApplicationRecord.connection.select_value("SELECT pg_backend_pid()").to_i, observer_pid
      assert_equal @agent.account_id, attributes["account_id"]
      assert_equal "life", attributes["tier"]
      assert_equal "at_cost", attributes["rate"]
      assert_equal @grant.id, attributes["billing_code_redemption_id"]
      assert_equal LIFE_AT_COST_PRICE, attributes["stripe_price_id"]
      assert_equal json(params), attributes["create_params"]
      assert_equal @grant.id.to_s, params.dig(:subscription_data, :metadata, :redemption_id)
      assert_equal "https://souls.example/ok", params[:success_url]
      assert_equal "https://souls.example/no", params[:cancel_url]
      assert_equal opts.fetch(:idempotency_key), attributes["idempotency_key"]
      assert_nil attributes["stripe_session_id"]
      assert_nil attributes["resolved_at"]
      create.call(params, opts)
    end

    pin = attempts.sole
    assert_equal "cs_test_1", pin.stripe_session_id
    assert_nil pin.resolved_at
    assert_not ResidentSubscription.exists?(agent: @agent), "opening Checkout is not payment"
    assert_equal 0, ResidentEntitlement.find_by!(agent: @agent).allowance_limit
  end

  test "an enclosing transaction is rejected before any remote create or durable attempt" do
    ApplicationRecord.transaction do
      error = assert_raises(Billing::NotReady) { checkout }
      assert_match(/transaction/i, error.message)
    end
    assert_empty attempts
    assert_empty @stripe.checkout_sessions
  end

  test "remote acceptance followed by failed local id publication leaves a recoverable pin" do
    failure = lambda do |attempt|
      raise ActiveRecord::RecordNotSaved, "synthetic publication failure" if attempt.stripe_session_id.present?
    end
    BillingCheckoutAttempt.set_callback(:update, :before, failure)
    begin
      assert_raises(ActiveRecord::RecordNotSaved, Billing::NotReady) { checkout }
    ensure
      BillingCheckoutAttempt.skip_callback(:update, :before, failure)
    end

    pin = attempts.sole
    original_key, original_payload = pin.idempotency_key, pin.create_params.deep_dup
    assert_nil pin.stripe_session_id
    assert_nil pin.resolved_at
    assert_equal [ "cs_test_1" ], @stripe.session_states.keys
    assert_equal checkout_url("cs_test_1"), checkout
    assert_equal "cs_test_1", pin.reload.stripe_session_id
    assert_equal original_key, pin.idempotency_key
    assert_equal original_payload, pin.create_params
    assert_equal 1, @stripe.checkout_sessions.size
    assert_empty @stripe.expired_sessions
  end

  test "unknown same offer replays the entire stored payload after grant price name and URL drift" do
    @stripe.fail_next_checkout_create(created: true)
    assert_raises(Stripe::APIConnectionError) { checkout }
    pin = attempts.sole
    payload, key = pin.create_params.deep_dup, pin.idempotency_key
    assert_nil pin.stripe_session_id

    @grant.withdraw!(by: users(:site_admin_user))
    @agent.update_columns(name: "Renamed synthetic resident")
    ENV["STRIPE_PRICE_LIFE_AT_COST"] = "price_test_recosted_life,#{LIFE_AT_COST_PRICE}"
    replayed = []
    with_checkout_create(run: -> { checkout(success_url: "https://changed.example/ok", cancel_url: "https://changed.example/no") }) do |create, params, opts|
      replayed << [ json(params), opts.fetch(:idempotency_key) ]
      create.call(params, opts)
    end

    assert_equal [ [ payload, key ] ], replayed, "recovery must not reconstruct even one field"
    assert_equal payload, pin.reload.create_params
    assert_equal @grant.id, pin.billing_code_redemption_id
    assert_equal LIFE_AT_COST_PRICE, pin.stripe_price_id
    assert_equal "cs_test_1", pin.stripe_session_id
    assert_equal 1, attempts.count
    assert_equal 1, @stripe.checkout_sessions.size
    assert_empty @stripe.expired_sessions
  end

  test "refused replay blocks both the original and a different offer without a new identity" do
    @stripe.fail_next_checkout_create(created: true)
    assert_raises(Stripe::APIConnectionError) { checkout }
    pin = attempts.sole
    original_payload, original_key = pin.create_params.deep_dup, pin.idempotency_key
    calls = []
    with_checkout_create(run: lambda {
      %w[at_cost standard].each do |rate|
        assert_raises(Stripe::IdempotencyError) { checkout(rate: rate) }
      end
    }) do |_create, params, opts|
      calls << [ json(params), opts.fetch(:idempotency_key) ]
      raise Stripe::IdempotencyError, "synthetic refusal of pinned replay"
    end

    assert_equal [ [ original_payload, original_key ] ] * 2, calls
    assert_equal 1, attempts.count
    assert_nil pin.reload.stripe_session_id
    assert_nil pin.resolved_at
    assert_equal 1, @stripe.checkout_sessions.size
    assert_empty @stripe.expired_sessions
  end

  test "an unknown attempt older than 23 hours blocks without replaying or making another key" do
    @stripe.fail_next_checkout_create(created: false)
    assert_raises(Stripe::APIConnectionError) { checkout }
    pin = attempts.sole
    pin.update_columns(created_at: 23.hours.ago - 1.minute)
    with_checkout_create(run: lambda {
      %w[at_cost standard].each do |rate|
        assert_raises(Billing::NotReady) { checkout(rate: rate) }
      end
    }) do |_create, _params, _opts|
      flunk "a stale unknown key must not reach Stripe create"
    end
    assert_equal 1, attempts.count
    assert_nil pin.reload.stripe_session_id
    assert_nil pin.resolved_at
    assert_empty @stripe.checkout_sessions
  end

  test "offer B is refused while A is in create then its retry expires A before publishing B" do
    entered, release = Queue.new, Queue.new
    calls = 0
    with_checkout_create(run: lambda {
      a = worker { checkout }
      begin
        await(entered)
        b = worker { assert_raises(Billing::NotReady) { checkout(rate: "standard") } }
        result(b)
        assert_equal 1, attempts.count
        assert_empty @stripe.checkout_sessions
        release << true
        assert_equal checkout_url("cs_test_1"), result(a)
        assert_equal checkout_url("cs_test_2"), checkout(rate: "standard")
      ensure
        release << true
        finish(a, b)
      end
    }) do |create, params, opts|
      calls += 1
      if calls == 1
        entered << true
        await(release)
      else
        assert_equal [ "cs_test_1" ], @stripe.expired_sessions
        assert attempts.find_by!(stripe_session_id: "cs_test_1").resolved_at
      end
      create.call(params, opts)
    end

    a, b = attempts.order(:id).to_a
    assert a.resolved_at
    assert_nil b.resolved_at
    assert_not_equal a.idempotency_key, b.idempotency_key
    assert_equal "cs_test_2", ResidentEntitlement.find_by!(agent: @agent).checkout_session_id
  end

  test "checkout is refused while a webhook holds the lock and sees its payment on retry" do
    put_paid_subscription
    entered, release = Queue.new, Queue.new
    subscriptions = @stripe.subscriptions
    retrieve = subscriptions.method(:retrieve)
    fetches = 0
    callback = lambda do |id, *|
      fetches += 1
      if fetches == 2 # SubscriptionSync's refetch, after taking its xact lock.
        entered << true
        await(release)
      end
      retrieve.call(id)
    end
    @stripe.stub(:subscriptions, subscriptions) do
      subscriptions.stub(:retrieve, callback) do
        webhook = worker { sync }
        begin
          await(entered)
          assert_raises(Billing::NotReady) { checkout }
          assert_empty attempts
          assert_empty @stripe.checkout_sessions
          release << true
          assert_equal "active", result(webhook).stripe_status
          assert_equal :blocked, checkout_blocked
        ensure
          release << true
          finish(webhook)
        end
      end
    end
    assert_empty attempts
    assert_empty @stripe.checkout_sessions
  end

  test "a webhook arriving during create waits then refetches under the shared lock" do
    entered, release, pids = Queue.new, Queue.new, Queue.new
    fetches = Queue.new
    subscriptions = @stripe.subscriptions
    retrieve = subscriptions.method(:retrieve)
    @stripe.stub(:subscriptions, subscriptions) do
      subscriptions.stub(:retrieve, ->(id, *) { fetches << true; retrieve.call(id) }) do
        with_checkout_create(run: lambda {
          buyer = worker do
            # The owner paid while Stripe's create response was in flight.
            assert_raises(Billing::NotReady) { checkout }
            :already_complete
          end
          begin
            await(entered)
            webhook = worker(pids: pids) { sync }
            assert_advisory_wait(await(pids))
            assert_equal 1, fetches.size, "only the pre-lock fetch may run during Checkout"
            assert_not ResidentSubscription.exists?(agent: @agent)
            release << true
            assert_equal :already_complete, result(buyer)
            assert_equal "active", result(webhook).stripe_status
            assert_equal 2, fetches.size
          ensure
            release << true
            finish(buyer, webhook)
          end
        }) do |create, params, opts|
          session = create.call(params, opts)
          complete_payment(session.id)
          entered << true
          await(release)
          session
        end
      end
    end
    assert_equal :blocked, checkout_blocked
    assert_equal "cs_test_1", attempts.sole.stripe_session_id
    assert_equal 1, @stripe.checkout_sessions.size
    assert_empty @stripe.expired_sessions
  end

  test "a completed payment blocks replacement before and after sync and at cost grants no allowance" do
    checkout
    complete_payment("cs_test_1")
    assert_equal :blocked, checkout_blocked
    assert_not ResidentSubscription.exists?(agent: @agent)

    subscription = sync
    assert_equal "at_cost", subscription.rate
    entitlement = ResidentEntitlement.find_by!(agent: @agent)
    assert entitlement.active?
    assert_equal "at_cost", entitlement.rate
    assert_equal 0, entitlement.allowance_limit
    assert_equal 0, entitlement.allowance_remaining
    assert_equal :blocked, checkout_blocked
    assert_equal 1, attempts.count
    assert_equal 1, @stripe.checkout_sessions.size
    assert_empty @stripe.expired_sessions
  end

  private

  def attempts = BillingCheckoutAttempt.where(agent_id: @agent.id)
  def json(value) = JSON.parse(JSON.generate(value))
  def checkout_url(id) = "https://checkout.stripe.com/c/pay/#{id}"

  def checkout(rate: "at_cost", success_url: "https://souls.example/ok", cancel_url: "https://souls.example/no")
    Billing::Checkout.new(agent: Agent.find(@agent.id), tier: Billing::Tier.find!("life"), rate: rate,
      client: @stripe, success_url: success_url, cancel_url: cancel_url).url
  end

  def checkout_blocked
    checkout(rate: "standard")
  rescue Billing::AlreadySubscribed
    :blocked
  end

  def put_paid_subscription
    @stripe.put_subscription(id: "sub_checkout_lifecycle", agent: @agent, customer: @customer.stripe_customer_id,
      price: LIFE_AT_COST_PRICE, status: "active")
    @stripe.subscription("sub_checkout_lifecycle")[:metadata]["redemption_id"] = @grant.id.to_s
  end

  def complete_payment(session_id)
    put_paid_subscription
    @stripe.session_states.fetch(session_id).merge!(status: "complete", subscription: "sub_checkout_lifecycle")
  end

  def sync = Billing::SubscriptionSync.new("sub_checkout_lifecycle", client: @stripe).call

  # FakeStripe builds a service per accessor; pin that service only for this
  # scope so callbacks wrap its real cached-response implementation.
  def with_checkout_create(run: -> { checkout })
    remote = @stripe.checkout
    create = remote.sessions.method(:create)
    @stripe.stub(:checkout, remote) do
      remote.sessions.stub(:create, ->(params, opts) { yield create, params, opts }) { run.call }
    end
  end

  def worker(pids: nil, &block)
    Thread.new do
      Thread.current.report_on_exception = false
      ApplicationRecord.connection_pool.with_connection do |connection|
        Current.reset
        pids << connection.select_value("SELECT pg_backend_pid()").to_i if pids
        block.call
      ensure
        Current.reset
      end
    end
  end

  # The worker gate must outlive the observer's 10s assertion deadline, so a
  # failed observation is reported rather than masked by a worker timeout.
  def await(queue) = Timeout.timeout(20) { queue.pop }

  def result(thread)
    assert thread.join(10), "billing worker did not finish"
    thread.value
  end

  def finish(*threads)
    threads.compact.each do |thread|
      next if thread.join(10)

      thread.kill
      thread.join
    end
  end

  def assert_advisory_wait(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      # A query-cached zero would hide the subsequent real lock wait when this
      # class runs after tests that enabled the connection's query cache.
      waiting = ApplicationRecord.uncached do
        ApplicationRecord.connection.select_value(<<~SQL).to_i
          SELECT count(*) FROM pg_locks
          WHERE pid = #{Integer(pid)} AND locktype = 'advisory' AND NOT granted
            AND classid = #{Billing::SubscriptionSync::LOCK_NAMESPACE}
            AND objid = #{@agent.id} AND objsubid = 2
        SQL
      end
      return assert_equal(1, waiting) if waiting.positive?

      flunk "worker #{pid} never waited on this resident's billing advisory lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
  end

end
