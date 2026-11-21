require "test_helper"
require "support/comms_send_helpers"

# Real concurrency for CommsSending (WhatsApp spec §5): threads with their
# own database connections and committed rows, so the connection row lock and
# the claim's unique index are what is actually tested. Each thread's result
# is checked: a Result or the expected Refused, never an unexpected error.
# Not transactional; the rows made here are removed in teardown.
class CommsSendingConcurrencyTest < ActiveSupport::TestCase

  include CommsSendHelpers

  self.use_transactional_tests = false

  THREADS = 4

  setup do
    @owner = users(:user_1)
    @agent = agents(:research_assistant)
    @connection, @access, @chat = committed_whatsapp_fixture(agent: @agent, owner: @owner)
    @access.change_send_grant!(true, actor: @owner)
  end

  teardown do
    remove_committed_whatsapp_fixture(@connection)
  end

  test "simultaneous retries of one client_request_id make one record and one connector call" do
    calls, results = race { request("same") }

    assert results.all? { |result| result.is_a?(CommsSending::Result) }, results.inspect
    assert_equal 1, CommsSend.where(service_connection_id: @connection.id).count
    assert_equal 1, calls.size
    assert_equal 1, results.count(&:created)
    assert_equal [ calls.first ], results.map { |result| result.send.id }.uniq
  end

  test "simultaneous retries of a claim that was never dispatched make one connector call" do
    send, = CommsSending.claim!(connection: @connection, agent: @agent, chat: @chat, text: "hello", client_request_id: "stranded")
    calls, results = race { request("stranded") }

    assert results.all? { |result| result.is_a?(CommsSending::Result) && !result.created }, results.inspect
    assert_equal [ send.id ], calls
    assert_equal "sent", send.reload.status
  end

  test "concurrent new requests cannot pass the pacing cap together" do
    room = 2
    fill_dispatched(CommsSending::PER_MINUTE - room)

    index = Concurrent::AtomicFixnum.new
    calls, results = race { request("distinct-#{index.increment}") }

    created = results.select { |result| result.is_a?(CommsSending::Result) && result.created }
    refused = results.select { |result| result.is_a?(CommsSending::Refused) }
    assert_equal room, created.size, results.inspect
    assert_equal THREADS - room, refused.size
    assert refused.all? { |refusal| refusal.code == :rate_limited }
    assert_equal room, calls.size
    assert_equal CommsSending::PER_MINUTE, CommsSend.where(service_connection_id: @connection.id).count
  end

  # Pacing is per connection, so different residents' claims must also be
  # serialised: by the connection's row lock, not only by each resident's
  # own access row.
  test "concurrent new requests from different residents cannot pass the pacing cap together" do
    room = 2
    fill_dispatched(CommsSending::PER_MINUTE - room)
    residents = [ @agent, agents(:code_reviewer), agents(:with_save_memory_tool), agents(:without_tools) ]
    residents.drop(1).each do |agent|
      agent.agent_service_accesses.create!(service_connection: @connection, enabled: true).change_send_grant!(true, actor: @owner)
    end

    index = Concurrent::AtomicFixnum.new(-1)
    calls, results = race do
      agent = residents.fetch(index.increment)
      CommsSending.request!(connection: @connection, agent: agent, chat: @chat, text: "hello", client_request_id: "per-resident")
    end

    created = results.select { |result| result.is_a?(CommsSending::Result) && result.created }
    assert_equal room, created.size, results.inspect
    assert_equal THREADS - room, results.count { |result| result.is_a?(CommsSending::Refused) && result.code == :rate_limited }
    assert_equal room, calls.size
    assert_equal CommsSending::PER_MINUTE, CommsSend.where(service_connection_id: @connection.id).count
  end

  test "concurrent retries of an old pending backlog against a nearly full minute make one call" do
    room = 1
    fill_dispatched(CommsSending::PER_MINUTE - room)
    backlog = THREADS.times.map { |n| pending_backlog("backlog-#{n}") }

    index = Concurrent::AtomicFixnum.new(-1)
    calls, results = race do
      send = backlog.fetch(index.increment)
      request(send.client_request_id, text: send.text)
    end

    assert results.all? { |result| result.is_a?(CommsSending::Result) }, results.inspect
    assert_equal room, calls.size
    assert_equal THREADS - room, CommsSend.where(id: backlog.map(&:id), error_code: "refused_at_dispatch_rate_limited").count
    assert_equal CommsSending::PER_MINUTE, CommsSend.where(service_connection_id: @connection.id, dispatched_at: 1.minute.ago..).count
  end

  test "concurrent retries against a full budget make no connector calls" do
    fill_dispatched(CommsSending::PER_MINUTE)
    send = pending_backlog("backlog")

    calls, results = race { request("backlog", text: send.text) }

    assert results.all? { |result| result.is_a?(CommsSending::Result) }, results.inspect
    assert_empty calls
    assert_equal [ "failed", "refused_at_dispatch_rate_limited" ], [ send.reload.status, send.error_code ]
  end

  test "unknown and dispatched_at are committed before the connector is called" do
    send, = CommsSending.claim!(connection: @connection, agent: @agent, chat: @chat, text: "hello", client_request_id: "committed")
    seen = nil
    answer = lambda do |dispatched|
      # Another database connection sees only what is committed.
      seen = in_thread { CommsSend.find(dispatched.id).attributes.slice("status", "dispatched_at") }.value.last
      raise Timeout::Error, "the process dies here"
    end
    CommsConnector.stub(:send_text, answer) do
      assert_raises(Timeout::Error) { CommsSending.deliver!(send) }
    end

    assert_equal "unknown", seen["status"]
    assert seen["dispatched_at"]
    assert_equal "unknown", send.reload.status, "a crash mid-call leaves it unknown"
  end

  private

  def request(id, text: "hello")
    CommsSending.request!(connection: @connection, agent: @agent, chat: @chat, text: text, client_request_id: id)
  end

  def fill_dispatched(count)
    now = Time.current
    CommsSend.insert_all!((1..count).map do |n|
      { service_connection_id: @connection.id, agent_id: @agent.id, comms_chat_id: @chat.id, text: "earlier #{n}",
        client_request_id: "earlier-#{n}", status: "sent", requested_at: now - 10.seconds, dispatched_at: now - 10.seconds,
        provider_message_id: "3EB0#{SecureRandom.hex(8).upcase}", connection_generation: @connection.pairing_attempt,
        created_at: now, updated_at: now }
    end)
  end

  def pending_backlog(id)
    @connection.comms_sends.create!(agent: @agent, comms_chat: @chat, text: "old #{id}", client_request_id: id,
                                    status: "pending", requested_at: 3.days.ago,
                                    provider_message_id: "3EB0#{SecureRandom.hex(8).upcase}", connection_generation: @connection.pairing_attempt)
  end

  # Runs the block in THREADS threads released together. The fake connector
  # takes a moment, as a real one would. Returns the connector calls and each
  # thread's result, or the CommsSending::Refused it raised; any other
  # exception fails the test.
  def race(&block)
    calls = Queue.new
    gate = Concurrent::CountDownLatch.new(1)
    fake = lambda do |send|
      calls << send.id
      sleep 0.2
      sent_outcome(send)
    end
    outcomes = CommsConnector.stub(:send_text, fake) do
      threads = THREADS.times.map do
        in_thread do
          gate.wait
          block.call
        rescue CommsSending::Refused => refusal
          refusal
        end
      end
      sleep 0.05
      gate.count_down
      threads.map { |thread| assert_thread_ok(thread) }
    end
    drained = []
    drained << calls.pop until calls.empty?
    [ drained, outcomes ]
  end

end
