require "test_helper"
require "webmock/minitest"

# eOyrdJ, 13 Nov 2026: a Cloudflare challenge on the provider's edge ate a
# resident's turns and the nudge with them, and the room waited for a person.
class ProviderEdgeRetryTest < ActiveSupport::TestCase

  CHALLENGE = { "status" => "error", "error_kind" => "provider_challenge",
                "runtime_failure" => { "code" => "clamp_runtime_failed", "message" => "API Error: 403 Cloudflare" } }.freeze

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "external", uuid: SecureRandom.uuid_v7, endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid", health_state: "healthy", consecutive_health_failures: 0
    )
    @chat = room("Edge")
  end

  test "a provider-edge failure queues a backoff wake; other failures do not" do
    assert_enqueued_with(job: ProviderEdgeRetryJob) { finish(running_run, "failed", response_body: CHALLENGE) }
    assert_no_enqueued_jobs(only: ProviderEdgeRetryJob) do
      finish(running_run, "failed", response_body: { "status" => "error", "error_kind" => "auth_expired" })
    end
  end

  test "a backoff wake wakes the room once, says why, and tells the run what happened" do
    failed = failed_run
    assert_difference -> { AgentRuntimeInteraction.where(provider_retry_of: failed).count }, 1 do
      assert_equal :woken, ProviderEdgeRetry.new(failed).wake!(:backoff)
      # A duplicate job, or a recovery asking for the same run, finds it taken.
      assert_not_equal :woken, ProviderEdgeRetry.new(failed).wake!(:backoff)
      assert_not_equal :woken, ProviderEdgeRetry.new(failed).wake!(:recovery)
    end
    notice = @chat.messages.where(role: "user").last.content
    assert_match "failed: its model provider's edge answered with HTTP 403, a Cloudflare challenge page", notice
    assert_not_includes notice, "API Error"
    prompt = ProviderEdgeRetry.new(failed).prompt_text
    assert_match "PROVIDER RETRY (platform, not a person)", prompt
    assert_match "grants no new permissions", prompt
  end

  test "nothing is woken when something came after the failure, or the resident is paused, or the room is closed" do
    failed = failed_run
    running_run(created_at: 1.minute.from_now)
    assert_equal :superseded, ProviderEdgeRetry.new(failed).wake!(:backoff)

    paused = failed_run(chat: other_room)
    @agent.update!(paused: true)
    assert_equal :unavailable, ProviderEdgeRetry.new(paused).wake!(:backoff)
    @agent.update!(paused: false)

    closed_room = third_room
    closed = failed_run(chat: closed_room)
    closed_room.update_columns(manual_responses: false)
    assert_equal :unavailable, ProviderEdgeRetry.new(closed).wake!(:backoff)
    assert_equal 0, AgentRuntimeInteraction.where.not(provider_retry_of_id: nil).count
  end

  test "the cap, end to end: two backoff wakes, one recovery, then nothing however many successes follow" do
    root = failed_run
    jobs = []
    ProviderEdgeRetryJob.stub(:set, ->(wait:) { jobs << wait; ProviderEdgeRetryJob }) do
      ProviderEdgeRetryJob.stub(:perform_later, ->(*) { }) { ProviderEdgeRetry.schedule(root) }
    end
    assert_equal [ 2.minutes ], jobs

    # Backoff 1 and 2: each wake's run fails on the edge again.
    first = wake_and_fail(root, :backoff)
    assert_equal 1, ProviderEdgeRetry.new(first).depth
    second = wake_and_fail(first, :backoff)
    assert_equal 2, ProviderEdgeRetry.new(second).depth
    # No third backoff: BACKOFF has two steps.
    assert_no_enqueued_jobs(only: ProviderEdgeRetryJob) { ProviderEdgeRetry.schedule(second) }

    # A success elsewhere recovers the room once; that recovery fails too.
    recovered = complete_elsewhere!
    third = AgentRuntimeInteraction.find_by!(provider_retry_of: second)
    fail!(third)
    assert_no_enqueued_jobs(only: ProviderEdgeRetryJob) { ProviderEdgeRetry.schedule(third) }

    # Later successes wake nothing more: the chain has had MAX_WAKES.
    3.times { complete_elsewhere! }
    ProviderEdgeRetryJob.perform_now(recovered.id, "recovery")
    assert_equal :chain_full, ProviderEdgeRetry.new(third).wake!(:recovery)
    assert_equal ProviderEdgeRetry::MAX_WAKES, AgentRuntimeInteraction.where(chat: @chat).where.not(provider_retry_of_id: nil).count
    assert_equal ProviderEdgeRetry::MAX_WAKES + 1, AgentRuntimeInteraction.where(chat: @chat, agent: @agent).count
  end

  test "a new chain in the same room still stops at the room's cap" do
    ProviderEdgeRetry::MAX_WAKES.times do |i|
      run = failed_run(created_at: (i * 10).minutes.from_now)
      assert_equal :woken, ProviderEdgeRetry.new(run).wake!(:backoff)
      fail!(AgentRuntimeInteraction.find_by!(provider_retry_of: run))
    end
    # A failure that arrived another way (a person's wake) starts a fresh chain.
    fresh = failed_run(created_at: 1.hour.from_now)
    assert_equal 0, ProviderEdgeRetry.new(fresh).depth
    assert_equal :room_full, ProviderEdgeRetry.new(fresh).wake!(:backoff)
  end

  test "a completed run elsewhere picks up each waiting room once, and only those" do
    waiting = failed_run
    elsewhere = other_room
    answered = failed_run(chat: elsewhere)
    running_run(chat: elsewhere, created_at: 1.minute.from_now) # this room moved on
    plain = failed_run(chat: third_room, response_body: { "status" => "error" })

    completed = running_run(chat: fourth_room)
    assert_enqueued_with(job: ProviderEdgeRetryJob, args: [ completed.id, "recovery" ]) do
      finish(completed, "completed")
    end
    2.times { ProviderEdgeRetryJob.perform_now(completed.id, "recovery") }

    assert_equal 1, AgentRuntimeInteraction.where(provider_retry_of: waiting).count
    assert_match "A later run of #{@agent.name}'s completed", @chat.messages.where(role: "user").last.content
    assert_equal 0, AgentRuntimeInteraction.where(provider_retry_of: [ answered, plain ]).count
  end

  # Mira's #938 review, finding 1.
  test "a pause after the retry is reserved stops it before it reaches the runtime" do
    failed = failed_run
    assert_equal :woken, ProviderEdgeRetry.new(failed).wake!(:backoff)
    retry_run = AgentRuntimeInteraction.find_by!(provider_retry_of: failed)
    @agent.update!(paused: true)
    trigger = stub_request(:post, %r{agent\.example\.com})
    # Stopped by the job's own deferred-wake guard, before any request object
    # exists (the claim would refuse it too; this witnesses the guard).
    ExternalAgentResponseRequest.stub(:new, ->(**) { flunk "a paused retry must not reach a request" }) do
      ManualAgentResponseJob.perform_now(@chat, @agent, runtime_interaction_id: retry_run.id)
    end
    assert_not_requested trigger
    assert_equal "cancelled", retry_run.reload.execution_state
  end

  test "the claim refuses a retry that a pause, a newer run or the room cap overtook" do
    failed = failed_run
    assert_equal :woken, ProviderEdgeRetry.new(failed).wake!(:backoff)
    retry_run = AgentRuntimeInteraction.find_by!(provider_retry_of: failed)
    @agent.update!(paused: true)
    assert_not retry_run.claim_dispatch!
    assert_equal "cancelled", retry_run.reload.execution_state

    @agent.update!(paused: false)
    other = failed_run(chat: other_room, created_at: 2.minutes.from_now)
    assert_equal :woken, ProviderEdgeRetry.new(other).wake!(:backoff)
    retry_run = AgentRuntimeInteraction.find_by!(provider_retry_of: other)
    # An ordinary run of the resident arrives there and finishes before this
    # retry is claimed: reserve! only refused active runs; the claim refuses.
    later = 3.minutes.from_now
    AgentRuntimeInteraction.create!(agent: @agent, chat: other.chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "s", started_at: later, created_at: later, run_id: SecureRandom.uuid, execution_state: "completed", finished_at: later)
    assert_not retry_run.claim_dispatch!
    assert_equal "cancelled", retry_run.reload.execution_state

    capped_room = third_room
    ProviderEdgeRetry::MAX_WAKES.times do |i|
      run = failed_run(chat: capped_room, created_at: (i * 10 + 30).minutes.from_now)
      AgentRuntimeInteraction.create!(agent: @agent, chat: capped_room, trigger_kind: "conversation", requested_by: "souls.house",
        session_id: "s", started_at: run.finished_at, created_at: run.finished_at, run_id: SecureRandom.uuid,
        execution_state: "cancelled", finished_at: run.finished_at, provider_retry_of: run)
    end
    last = AgentRuntimeInteraction.where(chat: capped_room).where.not(provider_retry_of_id: nil).order(:created_at).last
    last.update_columns(execution_state: "queued", finished_at: nil)
    late = failed_run(chat: capped_room, created_at: 2.hours.from_now)
    assert_equal :room_full, ProviderEdgeRetry.new(late).wake!(:backoff)
  end

  # Mira's #938 review, finding 2: the checks run under the locks, so a newer
  # finished run seen at reservation stops the wake (not only an active one).
  test "a newer finished run of the resident in the room stops the wake" do
    failed = failed_run
    AgentRuntimeInteraction.create!(agent: @agent, chat: @chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "s", started_at: Time.current, run_id: SecureRandom.uuid, execution_state: "completed", finished_at: Time.current)
    assert_equal :superseded, ProviderEdgeRetry.new(failed).wake!(:recovery)
  end

  # Mira's #938 review, finding 3.
  test "two failed runs that ended in the same minute get distinct notices, so neither wake is rolled back" do
    at = Time.zone.parse("2026-11-13 10:00:05 UTC")
    first = failed_run(created_at: at)
    first.update_columns(finished_at: at)
    assert_equal :woken, ProviderEdgeRetry.new(first).wake!(:recovery, recovered_at: at + 10.seconds)
    child = fail!(AgentRuntimeInteraction.find_by!(provider_retry_of: first))
    child.update_columns(finished_at: at + 20.seconds)
    assert_equal :woken, ProviderEdgeRetry.new(child.reload).wake!(:recovery, recovered_at: at + 30.seconds)
    notices = @chat.messages.where(role: "user").order(:id).last(2).map(&:content)
    assert_equal 2, notices.uniq.size
    assert_match "(run #{first.run_id.first(8)})", notices.first
  end

  test "completed runs queue no recovery job when nothing waits" do
    assert_no_enqueued_jobs(only: ProviderEdgeRetryJob) { finish(running_run, "completed") }
  end

  private

  def other_room = room("Other")
  def third_room = room("Third")
  def fourth_room = room("Fourth")

  # Seated before the failed runs it holds were requested.
  def room(title)
    chat = @agent.account.chats.create!(title: title, manual_responses: true, agents: [ @agent ])
    chat.chat_agents.update_all(created_at: 2.hours.ago)
    chat
  end

  def wake_and_fail(failed, reason)
    assert_equal :woken, ProviderEdgeRetry.new(failed).wake!(reason)
    fail!(AgentRuntimeInteraction.find_by!(provider_retry_of: failed))
  end

  def fail!(run)
    run.update!(response_body: CHALLENGE, runtime_status: "error", runtime_returncode: 1)
    run.finish_execution!("failed")
    run.reload
  end

  def complete_elsewhere!
    run = running_run(chat: @elsewhere ||= room("Elsewhere"))
    run.finish_execution!("completed")
    ProviderEdgeRetryJob.perform_now(run.id, "recovery")
    run
  end

  def finish(run, state, **attrs)
    run.update!(attrs) if attrs.any?
    run.finish_execution!(state)
    run
  end

  def running_run(chat: @chat, created_at: Time.current)
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "#{@agent.uuid}-#{chat.id}", started_at: created_at, created_at: created_at, run_id: SecureRandom.uuid,
      execution_state: "running", execution_deadline_at: 10.minutes.from_now, runtime_status: "error", runtime_returncode: 1
    )
  end

  def failed_run(chat: @chat, response_body: CHALLENGE, provider_retry_of: nil, created_at: nil)
    @seq = (@seq || 30) - 1
    at = created_at ? created_at + 1.minute : @seq.minutes.ago
    AgentRuntimeInteraction.create!(
      agent: @agent, chat: chat, trigger_kind: "conversation", requested_by: "souls.house",
      session_id: "#{@agent.uuid}-#{chat.id}", started_at: at - 1.minute, created_at: at - 1.minute, run_id: SecureRandom.uuid,
      execution_state: "failed", finished_at: at, runtime_status: "error", runtime_returncode: 1,
      response_body: response_body, provider_retry_of: provider_retry_of
    )
  end

end
