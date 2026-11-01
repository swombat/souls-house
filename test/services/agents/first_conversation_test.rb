require "test_helper"

class Agents::FirstConversationTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @creator = @agent.account.owner
    @agent.update!(
      runtime: "external", health_state: "healthy", birth_committed_at: Time.current,
      uuid: SecureRandom.uuid_v7, created_by_user: @creator
    )
    clear_enqueued_jobs
  end

  def finish_orientation!
    @agent.update!(orientation_requested_at: Time.current, orientation_completed_at: Time.current)
  end

  # Stands in for ExternalAgentResponseRequest#call: claims the reserved run
  # through the real claim gate, then behaves as the outcome says.
  #   :reached        the request reached the runtime client (request_text written)
  #   :local_refusal  refused locally without calling Chaos (a 503/409 notice path)
  #   :died           the worker dies after claiming, before the request
  def stub_request(outcome = :reached, &block)
    calls = []
    fake = lambda do |**kwargs|
      calls << kwargs
      request = Object.new
      request.define_singleton_method(:call) do
        interaction = kwargs.fetch(:interaction)
        next({ status: 409, body: { "status" => "already_running" } }) unless interaction.claim_dispatch!

        case outcome
        when :reached
          interaction.update!(request_text: "the request")
          interaction.finish_execution!("completed")
          { status: 200 }
        when :local_refusal
          interaction.finish_execution!("failed")
          { status: 503, error: "external runtime unreachable" }
        when :died
          raise "worker died"
        end
      end
      request
    end
    ExternalAgentResponseRequest.stub(:new, fake, &block)
    calls
  end

  def open_and_reserve!
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    # The worker dies before the request is made: the run is reserved, unclaimed.
    ExternalAgentResponseRequest.stub(:new, ->(**) { raise "worker died" }) do
      assert_raises(RuntimeError) { Agents::FirstConversation.wake!(@agent) }
    end
    @agent.reload
  end

  def person_writes!(chat, text = "hello")
    chat.messages.create!(role: "user", user: @creator, content: text, suppress_automatic_dispatch: true)
  end

  def person_starts_chat!
    chat = @agent.account.chats.create!(title: "Hi", manual_responses: true, agent_ids: [ @agent.id ])
    person_writes!(chat)
    chat
  end

  test "a completed first wake opens the conversation, from any writer" do
    assert_enqueued_with(job: FirstConversationJob, args: [ @agent.id ]) { finish_orientation! }
  end

  test "orientation completing synchronously in OrientNewAgentJob opens the conversation" do
    request = Object.new
    def request.call = { status: 200 }
    ExternalAgentOrientationRequest.stub(:new, ->(**) { request }) do
      OrientNewAgentJob.perform_now(@agent.id)
    end
    assert_enqueued_jobs 1, only: FirstConversationJob
  end

  test "opens one conversation in Main with only the resident, and owes one greeting" do
    finish_orientation!
    assert_equal :opened, Agents::FirstConversation.open!(@agent)

    chat = @agent.reload.first_conversation_chat
    assert_equal "Research Assistant's first conversation", chat.title
    assert_nil chat.room
    assert chat.manual_responses?
    assert_equal [ @agent.id ], chat.agent_ids
    assert_empty chat.messages, "the house posts nothing"
    assert_equal "owed", @agent.first_conversation_greeting
    assert_enqueued_with(job: FirstConversationWakeJob, args: [ @agent.id ])
  end

  test "a failed orientation with a healthy runtime still opens it" do
    @agent.update!(orientation_last_error: "boom", orientation_last_error_at: Time.current)
    assert_enqueued_jobs 1, only: FirstConversationJob
    assert_equal :opened, Agents::FirstConversation.open!(@agent)
  end

  test "a failed orientation with an unhealthy runtime opens nothing" do
    @agent.update!(health_state: "unhealthy", orientation_last_error: "boom", orientation_last_error_at: Time.current)
    assert_enqueued_jobs 0, only: FirstConversationJob
    refute Agents::FirstConversation.trigger?(@agent)
  end

  test "residents born before the feature (no recorded creator) get nothing" do
    @agent.update!(created_by_user: nil)
    finish_orientation!
    assert_enqueued_jobs 0, only: FirstConversationJob
    assert_equal :not_new_birth, Agents::FirstConversation.open!(@agent)
  end

  test "a retry opens nothing new" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    assert_no_difference -> { Chat.count } do
      assert_equal :already_open, Agents::FirstConversation.open!(@agent)
      @agent.retry_orientation!
      @agent.update!(orientation_completed_at: Time.current)
      perform_enqueued_jobs(only: FirstConversationJob)
    end
  end

  test "a conversation a person already started is linked instead, and no greeting is owed" do
    existing = person_starts_chat!
    finish_orientation!
    assert_no_difference -> { Chat.count } do
      assert_equal :existing, Agents::FirstConversation.open!(@agent)
    end
    assert_equal existing, @agent.reload.first_conversation_chat
    assert_equal "skipped", @agent.first_conversation_greeting
    assert_enqueued_jobs 0, only: FirstConversationWakeJob
  end

  test "the owner's runtime test conversation is not a person-started conversation" do
    test_chat = @agent.account.chats.create!(title: "system: agent test for #{@agent.name}", manual_responses: true, agent_ids: [ @agent.id ])
    person_writes!(test_chat)
    finish_orientation!
    assert_equal :opened, Agents::FirstConversation.open!(@agent)
  end

  test "a person starting a conversation while it was being opened wins, and the empty one goes" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    opened = @agent.reload.first_conversation_chat
    theirs = person_starts_chat!

    calls = stub_request { assert_equal :skipped, Agents::FirstConversation.wake!(@agent) }
    assert_empty calls
    assert_equal theirs, @agent.reload.first_conversation_chat
    refute Chat.exists?(opened.id)
  end

  test "once a person has written in it, the ordinary reply answers them instead" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    person_writes!(@agent.reload.first_conversation_chat)

    calls = stub_request { assert_equal :skipped, Agents::FirstConversation.wake!(@agent) }
    assert_empty calls
    assert_equal "skipped", @agent.reload.first_conversation_greeting
  end

  test "the wake carries the reason, names the creator and states orientation" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    calls = stub_request { assert_equal :spent, Agents::FirstConversation.wake!(@agent) }

    kwargs = calls.first
    assert_equal @agent.first_conversation_chat, kwargs[:chat]
    assert_includes kwargs[:initiation_reason], "#{ResidentFacingName.for(@creator)}, who created this resident"
    assert_includes kwargs[:initiation_reason], "no prescribed greeting"
    assert_includes kwargs[:initiation_reason], "orientation completed"
    assert_equal "spent", @agent.reload.first_conversation_greeting
    assert_equal 1, @agent.first_conversation_attempts
    assert_equal @agent.first_conversation_interaction, kwargs[:interaction]
    assert_predicate @agent.first_conversation_woken_at, :present?
  end

  test "after a failed orientation the reason says so, and an owner standing in is named as owner" do
    @agent.update!(orientation_last_error: "boom", orientation_last_error_at: Time.current)
    first = Agents::FirstConversation.new(@agent)
    assert_includes first.reason_text, "did not complete"

    @agent.update_column(:created_by_user_id, User.where.not(id: @creator.id).first.id)
    @agent.reload.created_by_user.destroy!
    text = Agents::FirstConversation.new(@agent.reload).reason_text
    assert_includes text, "who owns the account"
    refute_includes text, "created this resident"
  end

  test "a quiet completion is final: no second wake, nothing for the sweep" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    stub_request { Agents::FirstConversation.wake!(@agent) }
    clear_enqueued_jobs

    calls = stub_request { assert_equal :not_owed, Agents::FirstConversation.wake!(@agent) }
    assert_empty calls
    FirstConversationSweepJob.perform_now
    assert_enqueued_jobs 0, only: [ FirstConversationJob, FirstConversationWakeJob ]
  end

  test "a local refusal that never called the runtime gives the greeting back" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    stub_request(:local_refusal) { assert_equal :unsent, Agents::FirstConversation.wake!(@agent) }
    @agent.reload
    assert_equal "owed", @agent.first_conversation_greeting
    assert_nil @agent.first_conversation_interaction_id
    assert_equal 1, @agent.first_conversation_attempts
  end

  test "the real request's model-unavailable refusal does not consume the greeting" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    unavailable = Struct.new(:ok?, :model, :provider, :problem).new(false, "gone/model", "openrouter", "unavailable")
    available = Struct.new(:ok?).new(true)
    selections = [ available ]
    Agents::ModelSelection.stub(:for, ->(*, **) { selections.shift || unavailable }) do
      ConversationModelEvent.stub(:unavailable!, nil) do
        assert_equal :unsent, Agents::FirstConversation.wake!(@agent)
      end
    end
    assert_equal "owed", @agent.reload.first_conversation_greeting
  end

  test "a runtime known to be unreachable or a missing model holds the greeting before any run is reserved" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    Agents::ModelSelection.stub(:for, ->(*, **) { Struct.new(:ok?).new(false) }) do
      assert_no_difference -> { AgentRuntimeInteraction.count } do
        assert_equal :model_unavailable, Agents::FirstConversation.wake!(@agent)
      end
    end
    assert_equal "owed", @agent.reload.first_conversation_greeting
  end

  test "unsent reservations are retried a few times, then dropped" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    Agents::FirstConversation::MAX_ATTEMPTS.times do
      stub_request(:local_refusal) { Agents::FirstConversation.wake!(@agent) }
    end
    assert_equal "skipped", @agent.reload.first_conversation_greeting
    calls = stub_request { assert_equal :not_owed, Agents::FirstConversation.wake!(@agent) }
    assert_empty calls
  end

  test "a worker dying between reserving the run and dispatching it is re-driven, once" do
    open_and_reserve!
    assert_equal "sent", @agent.first_conversation_greeting
    interaction = @agent.first_conversation_interaction
    assert_nil interaction.dispatch_claimed_at

    clear_enqueued_jobs
    FirstConversationSweepJob.perform_now
    assert_enqueued_with(job: FirstConversationWakeJob, args: [ @agent.id ])

    calls = stub_request { assert_equal :spent, Agents::FirstConversation.wake!(@agent) }
    assert_equal 1, calls.size
    assert_equal interaction, calls.first[:interaction], "the same reserved run, not a new one"
    assert_equal 1, @agent.reload.first_conversation_attempts
  end

  test "a duplicate dispatch of the same run can't send twice" do
    open_and_reserve!
    interaction = @agent.first_conversation_interaction
    assert interaction.claim_dispatch!
    calls = stub_request { Agents::FirstConversation.wake!(@agent) }
    assert_empty calls, "a claimed run is not driven again"
  end

  test "a worker dying after the claim but before the request is unsent once the run lapses" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    stub_request(:died) { assert_raises(RuntimeError) { Agents::FirstConversation.wake!(@agent) } }
    assert_equal "sent", @agent.reload.first_conversation_greeting
    assert_equal :pending, Agents::FirstConversation.new(@agent).settle!

    travel(AgentRuntimeInteraction::PREPARATION_WINDOW + 1.minute) do
      assert_equal :unsent, Agents::FirstConversation.new(@agent).settle!
    end
    assert_equal "owed", @agent.reload.first_conversation_greeting
  end

  test "a reserved run whose request reached the client is final even with no result" do
    open_and_reserve!
    interaction = @agent.first_conversation_interaction
    interaction.claim_dispatch!
    interaction.update!(request_text: "the request")
    travel(1.hour) do
      assert_equal :spent, Agents::FirstConversation.new(@agent).settle!
    end
    assert_equal "spent", @agent.reload.first_conversation_greeting
  end

  test "the claim refuses once a person has written in the conversation" do
    open_and_reserve!
    interaction = @agent.first_conversation_interaction
    person_writes!(@agent.first_conversation_chat)

    refute interaction.claim_dispatch!
    assert_equal "cancelled", interaction.reload.execution_state
    assert_equal "skipped", @agent.reload.first_conversation_greeting
  end

  test "the claim refuses once a person has started their own conversation, and removes only an empty house one" do
    open_and_reserve!
    interaction = @agent.first_conversation_interaction
    opened = @agent.first_conversation_chat
    theirs = person_starts_chat!

    refute interaction.claim_dispatch!
    assert_equal theirs, @agent.reload.first_conversation_chat
    refute Chat.exists?(opened.id)
  end

  test "the claim holds the greeting, not drops it, when the resident was paused meanwhile" do
    open_and_reserve!
    interaction = @agent.first_conversation_interaction
    @agent.update!(paused: true)
    refute interaction.claim_dispatch!
    assert_equal "owed", @agent.reload.first_conversation_greeting
  end

  test "a process dying after the chat is saved but before the wake is enqueued is recovered by the sweep" do
    finish_orientation!
    FirstConversationWakeJob.stub(:perform_later, ->(*) { raise "process died" }) do
      assert_raises(RuntimeError) { Agents::FirstConversation.open!(@agent) }
    end
    assert_equal "owed", @agent.reload.first_conversation_greeting
    clear_enqueued_jobs

    FirstConversationSweepJob.perform_now
    assert_enqueued_with(job: FirstConversationWakeJob, args: [ @agent.id ])
  end

  test "the sweep opens a conversation whose job was lost, and drops greetings owed past a day" do
    finish_orientation!
    clear_enqueued_jobs
    FirstConversationSweepJob.perform_now
    assert_enqueued_with(job: FirstConversationJob, args: [ @agent.id ])

    Agents::FirstConversation.open!(@agent)
    @agent.update_column(:birth_committed_at, 2.days.ago)
    FirstConversationSweepJob.perform_now
    assert_equal "skipped", @agent.reload.first_conversation_greeting
  end

  test "billing hold, pause and an unready runtime open nothing" do
    finish_orientation!
    @agent.stub(:billing_held?, true) do
      assert_equal :billing_held, Agents::FirstConversation.open!(@agent)
    end
    @agent.update!(paused: true)
    assert_equal :paused, Agents::FirstConversation.open!(@agent)
    @agent.update!(paused: false, health_state: "unhealthy")
    assert_equal :runtime_not_ready, Agents::FirstConversation.open!(@agent)
    assert_nil @agent.reload.first_conversation_chat_id
  end

  test "a pause after opening holds the greeting rather than sending it" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    @agent.update!(paused: true)
    calls = stub_request { assert_equal :paused, Agents::FirstConversation.wake!(@agent) }
    assert_empty calls
    assert_equal "owed", @agent.reload.first_conversation_greeting
  end

  test "the page sees the conversation, and a reply only once the resident posts during a run" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    chat = @agent.reload.first_conversation_chat
    assert_equal({ id: chat.to_param, has_reply: false }, Agents::FirstConversation.presentation(@agent))

    chat.messages.create!(role: "assistant", agent: @agent, content: "_Research Assistant is currently unreachable._")
    refute Agents::FirstConversation.presentation(@agent)[:has_reply]

    interaction = AgentRuntimeInteraction.create!(agent: @agent, chat: chat, trigger_kind: "conversation",
      conversation_obfuscated_id: chat.to_param, requested_by: "house", session_id: "s", started_at: Time.current)
    detection = SafeguardDetection.create!(
      agent: @agent, channel: "conversation", response_text: "A scripted response.",
      prefilter_reason: "test", classifier_verdict: "detected", classifier_reason: "test", detector_version: "test"
    )
    chat.messages.create!(role: "assistant", agent: @agent, content: detection.response_text,
      runtime_interaction_id: interaction.id, safeguard_detection: detection)
    refute Agents::FirstConversation.presentation(@agent)[:has_reply], "a safeguard-labelled post is the house's, not the resident's"

    detection.update!(reclaimed_at: Time.current)
    assert Agents::FirstConversation.presentation(@agent)[:has_reply], "once reclaimed it is the resident's again"

    chat.messages.create!(role: "assistant", agent: @agent, content: "Hello.", runtime_interaction_id: interaction.id)
    assert Agents::FirstConversation.presentation(@agent)[:has_reply]
  end

  # Queued turns (SOULSHOUSE_ASYNC_TURNS): the greeting is claimed, then
  # waits for capacity as a ResidentTurn, possibly for a long time.
  def queue_greeting_turn!
    open_and_reserve!
    interaction = @agent.first_conversation_interaction
    assert interaction.claim_dispatch!
    interaction.update!(request_text: "the request", endpoint_url: "https://runtime.example.test")
    ResidentTurn.enqueue!(interaction, { session_id: interaction.session_id, request: "the request" })
  end

  test "a queued greeting is withdrawn at admission once a person has written, and their wake is kept" do
    ResidentTurn.stub(:enabled?, true) do
      Setting.instance.update!(resident_turn_limit: 0)
      turn = queue_greeting_turn!
      assert_empty ResidentTurn.admit!, "capacity is blocked"

      chat = @agent.first_conversation_chat
      # Inference credentials differ between machines; the hold is what matters here.
      Agents::InferenceAvailability.stub(:dispatchable?, true) do
        chat.messages.create!(role: "user", user: @creator, content: "hello there")
      end
      assert PendingWake.open.exists?(chat: chat, agent: @agent), "the person's wake is held behind the queued greeting"

      Setting.instance.update!(resident_turn_limit: 2)
      clear_enqueued_jobs
      assert_empty ResidentTurn.admit!
      assert_equal "cancelled", turn.reload.state
      assert_nil turn.admitted_at
      assert_equal "skipped", @agent.reload.first_conversation_greeting
      assert Chat.exists?(chat.id), "withdrawing the greeting leaves the conversation alone"
      assert_enqueued_with(job: PendingWakeJob, args: [ chat.id, @agent.id ])
      assert PendingWake.open.exists?(chat: chat, agent: @agent)
    end
  end

  test "an admitted greeting not yet submitted is withdrawn before submission once a person has written" do
    ResidentTurn.stub(:enabled?, true) do
      Setting.instance.update!(resident_turn_limit: 2)
      turn = queue_greeting_turn!
      assert_equal [ turn.id ], ResidentTurn.admit!

      person_writes!(@agent.first_conversation_chat)
      turn.reload.withdraw_unless_deliverable!
      assert_predicate turn.reload.cancel_requested_at, :present?
      assert_equal "skipped", @agent.reload.first_conversation_greeting
    end
  end

  test "a queued greeting cancelled before admission was never sent, and is owed again" do
    ResidentTurn.stub(:enabled?, true) do
      turn = queue_greeting_turn!
      assert_equal :pending, Agents::FirstConversation.new(@agent).settle!, "request_text alone is not delivery on the queued path"

      turn.cancel!
      assert_equal :unsent, Agents::FirstConversation.new(@agent).settle!
      assert_equal "owed", @agent.reload.first_conversation_greeting
    end
  end

  test "an admitted greeting that finished quietly is final" do
    ResidentTurn.stub(:enabled?, true) do
      Setting.instance.update!(resident_turn_limit: 2)
      turn = queue_greeting_turn!
      ResidentTurn.admit!
      turn.reload.update!(state: "finished", finished_at: Time.current)
      assert_equal :spent, Agents::FirstConversation.new(@agent).settle!
      calls = stub_request { assert_equal :not_owed, Agents::FirstConversation.wake!(@agent) }
      assert_empty calls
    end
  end

end
