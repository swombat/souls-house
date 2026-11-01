require "test_helper"
require "webmock/minitest"

# The notice is driven by AgentHealthCheckJob, so these run the job: the thing
# under test is "unhealthy for fifteen minutes, nobody told", not a method.
class ResidentUnreachableNoticeTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      consecutive_health_failures: 0
    )
    @down = stub_request(:get, "https://agent.example.com/health").to_return(status: 500)
  end

  def probe(times = 1)
    times.times { AgentHealthCheckJob.perform_now }
    @agent.reload
  end

  def up!
    remove_request_stub(@down)
    stub_request(:get, "https://agent.example.com/health").to_return(status: 200, body: "{}")
  end

  def outages
    AuditLog.where(action: ResidentUnreachableNotice::UNREACHABLE, auditable: @agent)
  end

  def recoveries
    AuditLog.where(action: ResidentUnreachableNotice::REACHABLE, auditable: @agent)
  end

  test "two failed probes say nothing" do
    probe(2)
    assert_equal "unhealthy", @agent.health_state
    assert_empty outages
  end

  test "the third failed probe opens one conversation in Main that wakes nobody" do
    probe(3)
    outage = outages.sole
    chat = Chat.find(outage.data.fetch("chat_id"))
    assert_nil chat.room
    assert_equal [ @agent ], chat.agents.to_a
    assert_equal @agent.account, chat.account
    assert_empty MessageDispatch.where(chat: chat)
    message = chat.messages.sole
    assert_equal "system", message.role
    assert_includes message.content, "hasn't answered the house since"
    assert_includes message.content, "Restarting #{@agent.name}"
    link = message.notice_link.stringify_keys
    assert_equal "Settings", link["label"]
    assert_equal Rails.application.routes.url_helpers.edit_account_agent_path(@agent.account, @agent, tab: "settings"), link["path"]
    assert_equal "unanswered", outage.data["kind"]
    assert_equal @agent.health_failing_since.iso8601, outage.data["since"]
  end

  test "an outage is said once however long it lasts" do
    probe(9)
    assert_equal "offline", @agent.runtime
    assert_equal 1, outages.count
    assert_equal 1, Chat.find(outages.sole.data.fetch("chat_id")).messages.count
  end

  test "recovery is said once, in the same conversation, and the next outage is a new notice" do
    probe(3)
    chat = Chat.find(outages.sole.data.fetch("chat_id"))
    up!
    probe(2)
    assert_equal 1, recoveries.count
    assert_equal outages.sole.id.to_s, recoveries.sole.data["outage_id"].to_s
    assert_equal 2, chat.messages.count
    assert_includes chat.messages.last.content, "answering again"
    assert_nil @agent.health_failing_since

    remove_request_stub(WebMock::StubRegistry.instance.request_stubs.first)
    stub_request(:get, "https://agent.example.com/health").to_return(status: 500)
    probe(3)
    assert_equal 2, outages.count
    assert_equal 1, recoveries.count
  end

  test "a resident asleep for billing is not reported" do
    ResidentEntitlement.create!(agent: @agent, account: @agent.account, source: "stripe", state: "held", tier: "life")
    probe(4)
    assert_empty outages
  end

  test "a switched-off resident is not reported" do
    @agent.update!(active: false)
    probe(4)
    assert_empty outages
  end

  test "a resident under a failed-roll hold is not reported twice" do
    @agent.update!(active: false, paused: true)
    ResidentSwitchedOffNotice.switched_off!(@agent, image: "fixture:new")
    @agent.update!(active: true, paused: false)
    # Switching back on closes the hold (Agent callback); reopen one by hand to
    # stand for a resident still held.
    ResidentSwitchedOffNotice.switched_off!(@agent, image: "fixture:newer")
    probe(4)
    assert_empty outages
  end

  test "a resident whose outage opened before it was switched off is still told it is back" do
    probe(3)
    @agent.update!(active: false)
    up!
    probe(1)
    assert_equal 1, recoveries.count
  end

  test "a crash loop that answers the probe is reported as restarting" do
    up!
    @agent.update!(container_name: "sh-test-research-assistant")
    counts = [ 1, 2, 3, 4, 5 ]
    sandbox = Object.new
    sandbox.define_singleton_method(:restart_count) { counts.shift }
    Agents::Sandbox.stub(:new, sandbox) do
      probe(4)
    end
    assert_equal "unhealthy", @agent.health_state
    assert_equal "restarting", @agent.health_failure_kind
    assert_equal 3, @agent.consecutive_health_failures
    outage = outages.sole
    assert_equal "restarting", outage.data["kind"]
    message = Chat.find(outage.data.fetch("chat_id")).messages.sole
    assert_includes message.content, "keeps restarting"
    assert_includes message.content, "may not help"
  end

  test "a notice that cannot be written does not stop the probe" do
    Chat.stub(:create_with_message!, ->(*) { raise "no chat today" }) do
      probe(3)
    end
    assert_equal 3, @agent.consecutive_health_failures
    assert_empty outages
  end

end
