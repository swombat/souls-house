require "test_helper"

class MessageHandoffTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @user = users(:user_1)
    @account = @user.personal_account
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router")
    @lume = @account.agents.create!(name: "Lume", system_prompt: "Test", runtime: "external")
    @mira = @account.agents.create!(name: "Mira", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.new(title: "Handoffs", manual_responses: true)
    @chat.agents = [ @lume, @mira ]
    @chat.save!
  end

  # Reading the tag

  test "a resident's explicit tag of another resident writes one pending request and knocks after commit" do
    message = nil
    assert_enqueued_with(job: MessageHandoffJob) do
      message = post_as_lume("@Mira, ready for your re-review of the pinned head.")
    end
    handoff = message.handoffs.sole
    assert_equal [ @mira, @lume, "tag", "pending" ], [ handoff.recipient_agent, handoff.requester_agent, handoff.source, handoff.status ]
    assert_equal [ { "recipient_name" => "Mira", "state" => "queued" } ],
                 message.handoff_receipts.map { |r| r.stringify_keys.slice("recipient_name", "state") }
  end

  test "a tag in a quote, a code block, inline code or an escape rings no one" do
    [
      "> @Mira said this earlier",
      "```\n@Mira example\n```",
      "Write `@Mira` to hand off",
      "Escaped \\@Mira here"
    ].each do |content|
      message = post_as_lume(content)
      assert_empty message.handoffs, content
    end
    assert_no_enqueued_jobs(only: MessageHandoffJob) { post_as_lume("> @Mira quoted again") }
  end

  test "tagging yourself does nothing, and a message made any other way hands off to no one" do
    assert_empty post_as_lume("@Lume note to self").handoffs
    message = @chat.messages.create!(role: "assistant", agent: @lume, content: "@Mira from somewhere other than the API")
    assert_empty message.handoffs
  end

  test "recipient_agent_ids names a recipient without a tag; a tag and a field for the same resident is one request" do
    field = post_as_lume("Ready when you are.", recipients: [ @mira.id ])
    assert_equal [ [ @mira.id, "field" ] ], field.handoffs.pluck(:recipient_agent_id, :source)

    both = post_as_lume("@Mira ready now.", recipients: [ @mira.id ])
    assert_equal [ [ @mira.id, "tag" ] ], both.handoffs.pluck(:recipient_agent_id, :source)
  end

  # Waking

  test "a free recipient is woken once, however often the job is delivered" do
    handoff = post_as_lume("@Mira over to you").handoffs.sole
    live do
      assert_difference -> { AgentRuntimeInteraction.where(agent: @mira).count }, 1 do
        handoff.dispatch!
        handoff.dispatch!
      end
    end
    handoff.reload
    assert_equal "triggered", handoff.status
    assert_equal @mira, handoff.runtime_interaction.agent
    assert_equal "queued", handoff.receipt_state
  end

  test "a busy recipient is held, not refused, with the message as the wake's source" do
    busy = AgentRuntimeInteraction.reserve!(agent: @mira, chat: @chat)
    handoff = post_as_lume("@Mira ready for review").handoffs.sole

    live { handoff.dispatch! }
    handoff.reload
    assert_equal "held", handoff.status
    source = handoff.pending_wake.sources.sole
    assert_equal [ "message", handoff.message_id, @lume.id ], [ source.kind, source.message_id, source.requester_agent_id ]
    assert busy.reload.finished_at.nil?
  end

  test "held, then released once with the message in the delta, then delivered when that run reads it" do
    busy = AgentRuntimeInteraction.reserve!(agent: @mira, chat: @chat)
    message = post_as_lume("@Mira ready for review")
    handoff = message.handoffs.sole
    live { handoff.dispatch! }

    # The busy run predates the message: it finishes without having read it.
    busy.update_columns(last_included_message_id: message.id - 1, transport_status: 200, runtime_status: "ok")
    busy.finish_execution!("completed")
    MessageHandoff.sync!(chat: @chat, agent: @mira)
    assert_equal "held", handoff.reload.status, "a run that started before the message has not delivered it"

    live do
      assert_difference -> { AgentRuntimeInteraction.where(agent: @mira).count }, 1 do
        PendingWake.release!(chat: @chat, agent: @mira)
        PendingWake.release!(chat: @chat, agent: @mira)
      end
    end
    MessageHandoff.sync!(chat: @chat, agent: @mira)
    handoff.reload
    released = handoff.pending_wake.released_interaction
    assert_equal [ "triggered", released ], [ handoff.status, handoff.runtime_interaction ]

    released.update_columns(last_included_message_id: message.id, transport_status: 200, runtime_status: "ok")
    released.finish_execution!("completed")
    MessageHandoff.sync!(chat: @chat, agent: @mira)
    assert_equal "delivered", handoff.reload.receipt_state
    assert handoff.delivered_at
  end

  test "the run's own commits bring the receipt up to date" do
    handoff = post_as_lume("@Mira look").handoffs.sole
    live { handoff.dispatch! }
    run = handoff.reload.runtime_interaction

    assert_enqueued_with(job: MessageHandoffSyncJob, args: [ @chat.id, @mira.id ]) do
      run.update!(last_included_message_id: handoff.message_id, transport_status: 200, runtime_status: "ok")
    end
    perform_enqueued_jobs(only: MessageHandoffSyncJob)
    assert_equal "delivered", handoff.reload.status
  end

  test "a triggered run that ends without reading the message is blocked, and a later reading still delivers it" do
    handoff = post_as_lume("@Mira look").handoffs.sole
    live { handoff.dispatch! }
    run = handoff.reload.runtime_interaction
    run.finish_execution!("failed")
    MessageHandoff.sync!(chat: @chat, agent: @mira)
    assert_equal [ "blocked", "run_failed" ], [ handoff.reload.status, handoff.reason ]

    later = AgentRuntimeInteraction.reserve!(agent: @mira, chat: @chat)
    later.update_columns(last_included_message_id: handoff.message_id, transport_status: 200, runtime_status: "ok")
    later.finish_execution!("completed")
    MessageHandoff.sync!(chat: @chat, agent: @mira)
    assert_equal [ "delivered", nil ], [ handoff.reload.status, handoff.reason ]
  end

  test "a message already read by the time the job runs is delivered without a wake" do
    handoff = post_as_lume("@Mira look").handoffs.sole
    seen = AgentRuntimeInteraction.reserve!(agent: @mira, chat: @chat)
    seen.update_columns(last_included_message_id: handoff.message_id, transport_status: 200, runtime_status: "ok")
    seen.finish_execution!("completed")

    assert_no_difference -> { AgentRuntimeInteraction.count } do
      live { handoff.dispatch! }
    end
    assert_equal "delivered", handoff.reload.status
  end

  test "the receipt under the message moves live, as a patch, without reordering the room" do
    handoff = post_as_lume("@Mira look").handoffs.sole
    updated_at = @chat.reload.updated_at

    live { handoff.dispatch! }
    assert_broadcast_on("Chat:#{@chat.obfuscated_id}",
      action: "handoff_receipts", chat_id: @chat.to_param, message_id: handoff.message.to_param,
      handoff_receipts: handoff.message.reload.handoff_receipts.map(&:stringify_keys))
    assert_equal updated_at, @chat.reload.updated_at
  end

  # Claim: an immediate wake is checked again before it starts, as a held
  # one's release is (Mira's review of #283).

  test "an immediate wake starts while its request stands" do
    handoff = post_as_lume("@Mira look").handoffs.sole
    live { handoff.dispatch! }
    assert handoff.reload.runtime_interaction.claim_dispatch!
  end

  test "an immediate wake whose message was discarded after reservation is refused at its claim" do
    handoff = post_as_lume("@Mira look").handoffs.sole
    live { handoff.dispatch! }
    run = handoff.reload.runtime_interaction
    handoff.message.discard!

    assert_not run.claim_dispatch!
    assert_equal "cancelled", run.reload.execution_state
    assert_equal [ "blocked", "discarded" ], [ handoff.reload.status, handoff.reason ]
  end

  test "an immediate wake whose recipient was paused after reservation is refused at its claim" do
    handoff = post_as_lume("@Mira look").handoffs.sole
    live { handoff.dispatch! }
    run = handoff.reload.runtime_interaction
    @mira.update!(paused: true)

    assert_not run.claim_dispatch!
    assert_equal "cancelled", run.reload.execution_state
    assert_equal [ "blocked", "paused" ], [ handoff.reload.status, handoff.reason ]
  end

  test "an already claimed immediate wake is not cancelled by a later refusal" do
    handoff = post_as_lume("@Mira look").handoffs.sole
    live { handoff.dispatch! }
    run = handoff.reload.runtime_interaction
    assert run.claim_dispatch!
    @mira.update!(paused: true)

    assert_not run.claim_dispatch!
    assert_equal "preparing", run.reload.execution_state
    assert_equal "triggered", handoff.reload.status
  end

  # Authority

  test "a discarded message, a paused recipient or an author who left the room blocks the request" do
    discarded = post_as_lume("@Mira one").handoffs.sole
    discarded.message.discard!
    live { discarded.dispatch! }
    assert_equal "discarded", discarded.reload.reason

    paused = post_as_lume("@Mira two").handoffs.sole
    @mira.update!(paused: true)
    live { paused.dispatch! }
    assert_equal "paused", paused.reload.reason
    @mira.update!(paused: false)

    left = post_as_lume("@Mira three").handoffs.sole
    @chat.agents.delete(@lume)
    live { left.dispatch! }
    assert_equal "author_not_in_room", left.reload.reason
  end

  test "a held request is withdrawn with its message, and the receipt says so" do
    AgentRuntimeInteraction.reserve!(agent: @mira, chat: @chat).tap do |busy|
      handoff = post_as_lume("@Mira later").handoffs.sole
      live { handoff.dispatch! }
      handoff.message.discard!
      busy.finish_execution!("completed")

      PendingWake.release!(chat: @chat, agent: @mira)
      MessageHandoff.sync!(chat: @chat, agent: @mira)
      assert_equal [ "blocked", "sources_withdrawn" ], [ handoff.reload.status, handoff.reason ]
    end
  end

  test "a request whose knock never ran is recorded by the sweeper, not retried" do
    handoff = post_as_lume("@Mira lost").handoffs.sole
    handoff.update_columns(created_at: (MessageHandoff::EXPIRY + 1.minute).ago)

    MessageDispatchSweepJob.perform_now
    assert_equal [ "blocked", "not_started_in_time" ], [ handoff.reload.status, handoff.reason ]
  end

  # Loop guard

  test "past the account's cap the request is blocked and the room is told once, until a person posts" do
    @account.update!(resident_handoff_cap: 2)
    2.times { |i| assert_equal "pending", post_as_lume("@Mira round #{i}").handoffs.sole.status }

    capped = nil
    assert_difference -> { @chat.messages.where(role: "system").count }, 1 do
      capped = post_as_lume("@Mira round 3").handoffs.sole
      post_as_lume("@Mira round 4")
    end
    assert_equal [ "blocked", "loop_cap" ], [ capped.status, capped.reason ]
    notice = @chat.messages.where(role: "system").last
    assert_match(/handed off to each other 2 times/, notice.content)
    assert_match(/did not wake Mira/, notice.content)
    assert_no_enqueued_jobs(only: MessageHandoffJob) { post_as_lume("@Mira round 5") }

    @chat.messages.create!(role: "user", user: @user, content: "Carry on")
    assert_equal "pending", post_as_lume("@Mira after a person").handoffs.sole.status
  end

  test "a cap of 0 turns handoffs off without a room notice" do
    @account.update!(resident_handoff_cap: 0)
    assert_no_difference -> { @chat.messages.where(role: "system").count } do
      handoff = post_as_lume("@Mira anyone").handoffs.sole
      assert_equal [ "blocked", "handoffs_off" ], [ handoff.status, handoff.reason ]
    end
  end

  test "the cap must be a whole number in range" do
    @account.resident_handoff_cap = "lots"
    assert_not @account.valid?
    @account.resident_handoff_cap = 51
    assert_not @account.valid?
    @account.resident_handoff_cap = "4"
    assert @account.valid?
    assert_equal 4, @account.resident_handoff_cap
  end

  private

  def post_as_lume(content, recipients: [])
    @chat.messages.create!(role: "assistant", agent: @lume, content: content, handoff_recipient_ids: recipients)
  end

  def live(&block)
    AgentRuntimeInteraction.stub(:live_activity_enabled?, true, &block)
  end

end
