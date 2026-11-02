require "test_helper"

class CommitmentTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @account = @user.personal_account
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router")
    @lume = @account.agents.create!(name: "Lume", system_prompt: "Test", runtime: "external")
    @mira = @account.agents.create!(name: "Mira", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.new(title: "Deploy thread", manual_responses: true)
    @chat.agents = [ @lume, @mira ]
    @chat.save!
    @now = Time.current.change(usec: 0)
  end

  # Saving

  test "a resident commits in a conversation it is in; the account is the conversation's" do
    commitment = commit("Check the 03:00 rebuild receipt", at: @now + 10.minutes)
    assert commitment.persisted?
    assert_equal @account, commitment.account
    assert_equal "scheduled", commitment.status
    assert_equal "same_conversation", commitment.destination
    assert_match(/scheduled for .* in this conversation\./, commitment.receipt)
  end

  test "due_at must be in the future and text is required" do
    late = build("Check it", at: @now - 1.minute)
    assert_not late.valid?
    assert late.errors[:due_at].present?
    blank = build("   ", at: @now + 1.hour)
    assert_not blank.valid?
    assert blank.errors[:text].present?
  end

  test "a resident outside the conversation cannot commit from it" do
    outsider = @account.agents.create!(name: "Outsider", system_prompt: "Test", runtime: "external")
    commitment = Commitment.new(agent: outsider, source_chat: @chat, text: "Look", due_at: @now + 1.hour)
    assert_not commitment.valid?
    assert commitment.errors[:agent].present?
  end

  test "the same text twice is refused while one is scheduled, whitespace and case aside" do
    first = commit("Check in on the deploy", at: @now + 5.minutes)
    again = build("  check IN on   the deploy ", at: @now + 20.minutes)
    assert_not again.valid?
    assert_match(/same as scheduled commitment #{first.to_param}/, again.errors[:text].join)

    assert commit("Check in on the deploy (second look)", at: @now + 20.minutes).persisted?
    # Another resident's identical text is its own promise.
    other = Commitment.create!(agent: @mira, source_chat: @chat, text: "Check in on the deploy", due_at: @now + 5.minutes)
    assert other.persisted?
  end

  test "the database refuses a duplicate the validation did not see" do
    commit("Check the receipt", at: @now + 5.minutes)
    duplicate = build("check the receipt", at: @now + 9.minutes)
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "a cancelled or activated commitment's text is free again" do
    cancelled = commit("Look again", at: @now + 5.minutes)
    cancelled.cancel!(by: @lume)
    assert commit("Look again", at: @now + 6.minutes).persisted?
  end

  test "a new conversation needs a room of the same account" do
    foreign = users(:regular_user).personal_account.rooms.create!(name: "Theirs")
    commitment = build("Elsewhere", at: @now + 1.hour, destination: "new_conversation", room: foreign)
    assert_not commitment.valid?
    assert commitment.errors[:room].present?
  end

  test "a room is only for a new conversation" do
    room = @account.rooms.create!(name: "Ops")
    commitment = build("Same thread", at: @now + 1.hour, room: room)
    assert_not commitment.valid?
    assert commitment.errors[:room].present?
  end

  test "the timezone is the owner's, as an IANA identifier the browser can use" do
    @account.owner.profile.update!(timezone: "Madrid")
    assert_equal "Madrid", @account.reload.owner.timezone
    commitment = commit("Zone", at: @now + 1.hour)
    assert_equal "Europe/Madrid", commitment.timezone
    assert_equal "Europe/Madrid", commitment.as_json[:timezone]
    assert_match(/ Europe\/Madrid \(/, commitment.receipt)
    @account.owner.profile.update!(timezone: nil)
    assert_equal "Etc/UTC", Commitment.find(commitment.id).timezone
  end

  # Activating

  test "a due commitment posts one house message here and wakes its resident once" do
    commitment = commit("Check the rebuild receipt and tell Daniel", at: @now + 1.minute)
    travel_to(@now + 2.minutes) do
      result = nil
      live do
        assert_difference -> { @chat.messages.where(role: "system").count }, 1 do
          assert_difference -> { AgentRuntimeInteraction.where(agent: @lume, chat: @chat).count }, 1 do
            result = commitment.activate!
            commitment.activate!
            Commitment.find(commitment.id).activate!
          end
        end
      end
      assert_equal :activated, result.status
    end
    commitment.reload
    assert_equal "activated", commitment.status
    assert_equal @chat, commitment.activation_chat
    assert_equal "woken", commitment.wake_state
    message = commitment.activation_message
    assert_equal "system", message.role
    assert_match(/\A\*\*Commitment due\.\*\* Lume committed to this\./, message.content)
    assert_includes message.content, "> Check the rebuild receipt and tell Daniel"
    assert_includes message.content, "what to do now is Lume's call"
    # Mira is not woken by Lume's commitment.
    assert_equal 0, AgentRuntimeInteraction.where(agent: @mira).count
  end

  test "a busy resident is held, not dropped" do
    commitment = commit("Back to this", at: @now + 1.minute)
    busy = AgentRuntimeInteraction.reserve!(agent: @lume, chat: @chat)
    travel_to(@now + 2.minutes) { live { commitment.activate! } }
    commitment.reload
    assert_equal "activated", commitment.status
    assert_equal "held", commitment.wake_state
    wake = PendingWake.open.find_by!(chat: @chat, agent: @lume)
    assert_equal wake, commitment.pending_wake
    assert_equal [ "trigger", @lume.id ], [ wake.sources.sole.kind, wake.sources.sole.requester_agent_id ]
    assert busy.reload.finished_at.nil?
  end

  # Custody of the wake

  test "a reservation refused for now posts once, then wakes on a later sweep" do
    commitment = commit("Back after the backup", at: @now + 1.minute)
    travel_to(@now + 2.minutes) do
      live do
        Backup::VmResident.stub(:held?, true) { commitment.activate! }
        assert_equal [ "activated", "retrying" ], [ commitment.reload.status, commitment.wake_state ]
        assert_match(/unavailable/, commitment.wake_reason)
        assert_equal 0, AgentRuntimeInteraction.where(agent: @lume, chat: @chat).count

        Backup::VmResident.stub(:held?, true) { commitment.sync_wake! }
        assert_equal "retrying", commitment.reload.wake_state

        assert_no_difference -> { @chat.messages.count } do
          commitment.sync_wake!
        end
      end
    end
    commitment.reload
    assert_equal [ "woken", 1 ], [ commitment.wake_state, commitment.wake_runs ]
    assert_equal commitment.wake_interaction, AgentRuntimeInteraction.find_by!(agent: @lume, chat: @chat)
  end

  test "delivered once the run carrying the cue ends ok, whatever the transcript window kept" do
    commitment = commit("Read me", at: @now + 1.minute)
    travel_to(@now + 2.minutes) { live { commitment.activate! } }
    run = commitment.reload.wake_interaction
    commitment.sync_wake!
    assert_equal "woken", commitment.reload.wake_state

    run.update_columns(finished_at: Time.current, execution_state: "completed", transport_status: 200, runtime_status: "ok",
                       dispatch_claimed_at: Time.current, last_included_message_id: commitment.activation_message_id - 1)
    commitment.sync_wake!
    assert_equal "delivered", commitment.reload.wake_state
    assert commitment.delivered_at.present?
    assert_not Commitment.wake_in_custody.exists?(commitment.id)
  end

  test "a run cancelled before it started is woken again, with no second message" do
    commitment = commit("Try again", at: @now + 1.minute)
    travel_to(@now + 2.minutes) do
      live do
        commitment.activate!
        commitment.reload.wake_interaction.update_columns(finished_at: Time.current, execution_state: "cancelled")
        commitment.sync_wake!
        assert_equal "retrying", commitment.reload.wake_state
        assert_no_difference -> { @chat.messages.count } do
          commitment.sync_wake!
        end
      end
    end
    assert_equal [ "woken", 2 ], [ commitment.reload.wake_state, commitment.wake_runs ]
  end

  test "a run that started and ended badly is not replayed" do
    commitment = commit("Uncertain", at: @now + 1.minute)
    travel_to(@now + 2.minutes) { live { commitment.activate! } }
    commitment.reload.wake_interaction.update_columns(finished_at: Time.current, execution_state: "outcome_unknown",
                                                      dispatch_claimed_at: Time.current)
    live do
      commitment.sync_wake!
      commitment.sync_wake!
    end
    commitment.reload
    assert_equal "blocked", commitment.wake_state
    assert_match(/outcome_unknown; not replayed/, commitment.wake_reason)
    assert_equal 1, AgentRuntimeInteraction.where(agent: @lume, chat: @chat).count
  end

  test "runs are started at most MAX_WAKE_RUNS times" do
    commitment = commit("Keep trying", at: @now + 1.minute)
    travel_to(@now + 2.minutes) do
      live do
        commitment.activate!
        (2 * Commitment::MAX_WAKE_RUNS + 2).times do
          run = commitment.reload.wake_interaction
          run.update_columns(finished_at: Time.current, execution_state: "busy") if run && run.finished_at.nil?
          commitment.sync_wake!
        end
      end
    end
    commitment.reload
    assert_equal "blocked", commitment.wake_state
    assert_match(/gave up after #{Commitment::MAX_WAKE_RUNS} runs/, commitment.wake_reason)
    assert_equal Commitment::MAX_WAKE_RUNS, AgentRuntimeInteraction.where(agent: @lume, chat: @chat).count
    assert_equal 1, @chat.messages.where(role: "system").count
  end

  test "a paused resident's retry waits with the reason instead of starting runs" do
    commitment = commit("Paused retry", at: @now + 1.minute)
    travel_to(@now + 2.minutes) { live { Backup::VmResident.stub(:held?, true) { commitment.activate! } } }
    @lume.update!(paused: true)
    live { commitment.sync_wake! }
    assert_equal [ "retrying", "resident_paused" ], [ commitment.reload.wake_state, commitment.wake_reason ]
    assert_equal 0, AgentRuntimeInteraction.where(agent: @lume, chat: @chat).count
  end

  test "a held wake that is dropped goes back to retrying; one released is followed to its run" do
    commitment = commit("While busy", at: @now + 1.minute)
    busy = AgentRuntimeInteraction.reserve!(agent: @lume, chat: @chat)
    travel_to(@now + 2.minutes) { live { commitment.activate! } }
    assert_equal "held", commitment.reload.wake_state
    commitment.pending_wake.update!(dropped_at: Time.current, drop_reason: "expired")
    commitment.sync_wake!
    assert_equal [ "retrying", "held wake dropped: expired" ], [ commitment.reload.wake_state, commitment.wake_reason ]
    busy.update_columns(finished_at: Time.current)
    live { commitment.sync_wake! }
    assert_equal "woken", commitment.reload.wake_state

    held_run = commitment.wake_interaction
    other = commit("Second while busy", at: @now + 1.minute)
    travel_to(@now + 2.minutes) { live { other.activate! } }
    assert_equal "held", other.reload.wake_state
    other.pending_wake.update!(released_at: Time.current, released_interaction: held_run)
    other.sync_wake!
    assert_equal [ "woken", held_run ], [ other.reload.wake_state, other.wake_interaction ]
  end

  test "a pause after the wake was reserved stops the run at claim and the commitment retries" do
    commitment = commit("Pause me", at: @now + 1.minute)
    travel_to(@now + 2.minutes) { live { commitment.activate! } }
    run = commitment.reload.wake_interaction
    @lume.update!(paused: true)
    live { assert_not run.claim_dispatch! }
    assert_equal "cancelled", run.reload.execution_state
    assert_equal [ "retrying", "claim_refused:resident_paused" ], [ commitment.reload.wake_state, commitment.wake_reason ]
  end

  test "the queued job does not send a paused resident's commitment wake" do
    commitment = commit("Paused before the job", at: @now + 1.minute)
    travel_to(@now + 2.minutes) { live { commitment.activate! } }
    run = commitment.reload.wake_interaction
    @lume.update!(paused: true)
    ExternalAgentResponseRequest.stub(:new, ->(**) { flunk "a paused resident's commitment wake was sent" }) do
      live { ManualAgentResponseJob.perform_now(@chat, @lume, runtime_interaction_id: run.id) }
    end
    assert_equal "cancelled", run.reload.execution_state
  end

  test "the run's request carries the commitment as its cue, direct or through a held wake" do
    commitment = commit("Check the 03:00 receipt", at: @now + 1.minute)
    travel_to(@now + 2.minutes) { live { commitment.activate! } }
    request = ExternalAgentResponseRequest.new(agent: @lume, chat: @chat, interaction: commitment.reload.wake_interaction)
    cue = request.send(:commitment_cue_text)
    assert_includes cue, "Commitment due: you committed to this"
    assert_includes cue, "> Check the 03:00 receipt"
    assert_includes cue, "message #{commitment.activation_message.to_param}"

    other = commit("Held cue", at: @now + 1.minute)
    travel_to(@now + 2.minutes) { live { other.activate! } }
    assert_equal "held", other.reload.wake_state
    commitment.wake_interaction.update_columns(finished_at: Time.current)
    released = live { AgentRuntimeInteraction.reserve!(agent: @lume, chat: @chat) }
    other.reload.pending_wake.update!(released_at: Time.current, released_interaction: released)
    cue = ExternalAgentResponseRequest.new(agent: @lume, chat: @chat, interaction: released).send(:commitment_cue_text)
    assert_includes cue, "> Held cue"
  end

  test "an ordinary run carries no commitment cue" do
    run = AgentRuntimeInteraction.reserve!(agent: @lume, chat: @chat)
    assert_nil ExternalAgentResponseRequest.new(agent: @lume, chat: @chat, interaction: run).send(:commitment_cue_text)
  end

  # Stopping after it was posted

  test "stopping a commitment that is the sole source of a held wake leaves no run for it" do
    commitment = commit("Sole source", at: @now + 1.minute)
    busy = AgentRuntimeInteraction.reserve!(agent: @lume, chat: @chat)
    travel_to(@now + 2.minutes) { live { commitment.activate! } }
    assert_equal "held", commitment.reload.wake_state
    assert_equal :cancelled, commitment.cancel!(by: @user).status
    assert_equal [ "cancelled", "withdrawn" ], [ commitment.reload.status, commitment.wake_state ]
    assert_not Commitment.wake_in_custody.exists?(commitment.id)

    busy.update_columns(finished_at: Time.current)
    live do
      assert_no_difference -> { AgentRuntimeInteraction.where(agent: @lume, chat: @chat).count } do
        PendingWake.release!(chat: @chat, agent: @lume)
      end
    end
    assert commitment.pending_wake.reload.dropped_at.present?
  end

  test "stopping one request on a shared held wake keeps the others'" do
    commitment = commit("Shared", at: @now + 1.minute)
    busy = AgentRuntimeInteraction.reserve!(agent: @lume, chat: @chat)
    travel_to(@now + 2.minutes) { live { commitment.activate! } }
    wake = commitment.reload.pending_wake
    PendingWake.queue!(chat: @chat, agent: @lume, requested_by: "Mira", requester_agent: @mira)
    assert_equal wake, PendingWake.open.find_by!(chat: @chat, agent: @lume)
    commitment.cancel!(by: @user)

    busy.update_columns(finished_at: Time.current)
    live do
      assert_difference -> { AgentRuntimeInteraction.where(agent: @lume, chat: @chat).count }, 1 do
        PendingWake.release!(chat: @chat, agent: @lume)
      end
    end
    released = wake.reload.released_interaction
    assert released.present?
    assert_nil ExternalAgentResponseRequest.new(agent: @lume, chat: @chat, interaction: released).send(:commitment_cue_text)
  end

  test "stopping a woken commitment refuses its run at claim" do
    commitment = commit("Stop me", at: @now + 1.minute)
    travel_to(@now + 2.minutes) { live { commitment.activate! } }
    run = commitment.reload.wake_interaction
    commitment.cancel!(by: @lume)
    live { assert_not run.claim_dispatch! }
    assert_equal "cancelled", run.reload.execution_state
    assert_equal "withdrawn", commitment.reload.wake_state
  end

  test "a delivered commitment cannot be cancelled" do
    commitment = commit("Done", at: @now + 1.minute)
    travel_to(@now + 2.minutes) { live { commitment.activate! } }
    commitment.update_columns(wake_state: "delivered")
    assert_equal :not_cancellable, commitment.reload.cancel!(by: @user).status
    assert_equal "activated", commitment.reload.status
  end

  test "a late delivery says it is late, with both times" do
    commitment = commit("Late one", at: @now + 1.minute)
    travel_to(@now + 45.minutes) { live { commitment.activate! } }
    content = commitment.reload.activation_message.content
    assert_match(/Due .*, delivered .* \(late\)/, content)
  end

  test "an undeliverable commitment posts nothing, records why, and fires once it can" do
    commitment = commit("When you are back", at: @now + 1.minute)
    @lume.update!(paused: true)
    travel_to(@now + 2.minutes) do
      live do
        assert_no_difference -> { Message.count } do
          assert_equal :waiting, commitment.activate!.status
        end
      end
    end
    commitment.reload
    assert_equal [ "scheduled", "resident_paused" ], [ commitment.status, commitment.waiting_reason ]
    assert commitment.last_attempted_at.present?

    @lume.update!(paused: false)
    travel_to(@now + 3.hours) { live { assert_equal :activated, commitment.activate!.status } }
    assert_nil commitment.reload.waiting_reason
    assert_match(/\(late\)/, commitment.activation_message.content)
  end

  test "live activity off waits rather than posting" do
    commitment = commit("Quiet", at: @now + 1.minute)
    travel_to(@now + 2.minutes) do
      AgentRuntimeInteraction.stub(:live_activity_enabled?, false) do
        assert_equal :waiting, commitment.activate!.status
      end
    end
    assert_equal "live_activity_disabled", commitment.reload.waiting_reason
  end

  test "an archived source conversation waits" do
    commitment = commit("In the archive", at: @now + 1.minute)
    @chat.update!(archived_at: Time.current)
    travel_to(@now + 2.minutes) { live { commitment.activate! } }
    assert_equal "conversation_unavailable", commitment.reload.waiting_reason
  end

  test "a new-conversation commitment opens one conversation in its room, linked to the origin" do
    room = @account.rooms.create!(name: "Ops")
    origin = @chat.messages.create!(role: "assistant", agent: @lume, content: "I'll rebuild at 03:00.", suppress_automatic_dispatch: true)
    commitment = commit("Rebuild residents and post the receipt in the deploy thread", at: @now + 1.minute,
      destination: "new_conversation", room: room, source_message: origin)
    travel_to(@now + 2.minutes) do
      live do
        assert_difference -> { Chat.count }, 1 do
          commitment.activate!
          commitment.activate!
        end
      end
    end
    commitment.reload
    chat = commitment.activation_chat
    assert_not_equal @chat, chat
    assert_equal room, chat.room
    assert_equal [ @lume ], chat.agents.to_a
    assert_equal "Commitment: Rebuild residents and post the receipt in the deploy thread".truncate(80), chat.title
    content = commitment.activation_message.content
    assert_includes content, "[Deploy thread](/accounts/#{@account.to_param}/chats/#{@chat.to_param})"
    assert_includes content, "(message #{origin.to_param})"
    assert_equal "woken", commitment.wake_state
  end

  test "a commitment not yet due, cancelled or already activated does nothing" do
    commitment = commit("Later", at: @now + 1.hour)
    assert_equal :not_due, commitment.activate!(now: @now).status
    commitment.cancel!(by: @user)
    assert_equal :not_scheduled, commitment.activate!(now: @now + 2.hours).status
    assert_equal [ "cancelled", @user ], [ commitment.reload.status, commitment.cancelled_by_user ]
    assert_equal :not_cancellable, commitment.cancel!(by: @user).status
  end

  test "reschedule moves a scheduled commitment and clears its waiting reason" do
    commitment = commit("Move me", at: @now + 1.hour)
    commitment.update_columns(waiting_reason: "resident_paused", last_attempted_at: @now)
    assert_equal :rescheduled, commitment.reschedule!(due_at: @now + 2.hours).status
    commitment.reload
    assert_equal [ @now + 2.hours, nil, 1 ], [ commitment.due_at, commitment.waiting_reason, commitment.reschedule_count ]
    assert_equal :invalid, commitment.reschedule!(due_at: @now - 1.hour).status
  end

  test "people who own the house or the resident's house may manage it" do
    commitment = commit("Mine", at: @now + 1.hour)
    assert commitment.manageable_by?(@account.owner)
    assert_not commitment.manageable_by?(users(:regular_user))
    assert_not commitment.manageable_by?(nil)
  end

  private

  def build(text, at:, agent: @lume, **attrs)
    Commitment.new(agent: agent, source_chat: @chat, text: text, due_at: at, **attrs)
  end

  def commit(text, at:, **attrs)
    build(text, at: at, **attrs).tap(&:save!)
  end

  def live(&block)
    AgentRuntimeInteraction.stub(:live_activity_enabled?, true, &block)
  end

end
