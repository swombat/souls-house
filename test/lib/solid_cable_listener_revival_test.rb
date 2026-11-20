require "test_helper"

# The real listener polls the cable database, which the test environment does
# not have. These listeners replace only the poll (broadcast_messages) and keep
# solid_cable's own thread, critical-section and shutdown code.
class SolidCableListenerRevivalTest < ActiveSupport::TestCase

  # Tests that share these listeners must not run their threads side by side.
  parallelize(workers: 1)

  Listener = ActionCable::SubscriptionAdapter::SolidCable.const_get(:Listener)

  class FlakyListener < Listener

    attr_reader :polls, :failures_raised

    def initialize(fail_times:)
      @fail_times = fail_times
      @failures_raised = Queue.new
      @polls = Queue.new
      super(Object.new)
    end

    private
      def broadcast_messages
        if @fail_times.nil? || @fail_times.positive?
          @fail_times -= 1 if @fail_times
          @failures_raised << Time.current
          raise ActiveRecord::ConnectionNotEstablished, "connection to server was lost"
        end

        @polls << :ok
      end

  end

  setup do
    SolidCableListenerRevival.retry_delays = [ 0.01 ]
    @listeners = []
  end

  teardown do
    @listeners.each { |listener| listener.shutdown if listener.send(:thread).alive? }
    SolidCableListenerRevival.retry_delays = nil
  end

  test "the listener keeps polling after the database fails under it" do
    listener = build(fail_times: 3)

    assert_equal :ok, pop(listener.polls), "listener never polled again after the failures"
    assert_equal 3, listener.failures_raised.size
    assert listener.send(:thread).alive?
  end

  test "a failure is reported, not silent" do
    reported = []
    subscriber = Object.new
    subscriber.define_singleton_method(:report) { |error, **context| reported << [ error, context ] }
    Rails.error.subscribe(subscriber)

    listener = build(fail_times: 1)
    pop(listener.polls)

    error, context = reported.find { |(_, ctx)| ctx.dig(:context, :component) == "solid_cable_listener" }
    assert_kind_of ActiveRecord::ConnectionNotEstablished, error
    assert_equal 1, context.dig(:context, :attempt)
  ensure
    Rails.error.unsubscribe(subscriber) if subscriber
  end

  test "shutdown still stops a listener that is waiting to retry" do
    SolidCableListenerRevival.retry_delays = [ 30 ]
    listener = build(fail_times: nil)
    pop(listener.failures_raised)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    listener.shutdown
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_not listener.send(:thread).alive?
    assert_operator elapsed, :<, 5, "shutdown waited out the retry delay"
  end

  test "shutdown still stops a healthy listener" do
    listener = build(fail_times: 0)
    pop(listener.polls)

    listener.shutdown

    assert_not listener.send(:thread).alive?
  end

  test "retry delays grow and then hold at the last one" do
    SolidCableListenerRevival.retry_delays = nil

    assert_equal [ 0.5, 1, 2, 5, 5, 5 ], (1..6).map { |n| SolidCableListenerRevival.delay_for(n) }
  end

  private
    def build(**options)
      FlakyListener.new(**options).tap { |listener| @listeners << listener }
    end

    def pop(queue)
      queue.pop(timeout: 5).tap { |value| assert value, "timed out waiting for the listener" }
    end

end
