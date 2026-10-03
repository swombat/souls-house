require "test_helper"

class RhythmDispatchTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @rhythm = Rhythm.create!(
      account: @agent.account, creator: users(:user_1), title: "Round",
      opening: "Please reflect together.", cadence: "daily", time_of_day: "09:00", timezone: "UTC",
      agents: [ @agent, agents(:code_reviewer) ]
    )
    @dispatch = @rhythm.fire!(manual: true, request_key: "round").occurrence.message_dispatch
  end

  test "rhythm dispatch reserves a linked resident round only once" do
    assert @dispatch.rhythm?
    assert @dispatch.from_message?
    assert_enqueued_jobs 1, only: ManualAgentResponseJob do
      2.times { MessageDispatchJob.perform_now(@dispatch) }
    end
    run = @dispatch.reload.runtime_interaction
    assert_equal @dispatch, run.message_dispatch
    assert_equal @dispatch.target_agent_ids.drop(1), run.response_chain_agent_ids
    assert run.claim_dispatch!
    assert_not run.claim_dispatch!
  end

  test "expired rhythm wake is recorded and not redriven" do
    travel MessageDispatch::EXPIRY + 1.minute do
      assert_no_enqueued_jobs { MessageDispatchSweepJob.perform_now }
      assert_equal "expired", @dispatch.reload.status
      assert_equal "not_started_in_time", @dispatch.reason
    end
  end

  test "discarding the opening cancels its pending rhythm wake" do
    @dispatch.message.discard_as_author!
    assert_equal "cancelled", @dispatch.reload.status
    assert_equal "discarded", @dispatch.reason
  end

  test "resident authored dispatch reserves and claims only once without human impersonation" do
    dispatch = resident_dispatch
    assert_nil dispatch.user
    assert_equal @agent, dispatch.message.agent
    assert_enqueued_jobs 1, only: ManualAgentResponseJob do
      2.times { MessageDispatchJob.perform_now(dispatch) }
    end
    interaction = dispatch.reload.runtime_interaction
    assert interaction.claim_dispatch!
    assert_not interaction.claim_dispatch!
  end

  test "resident authored dispatch rechecks creator at reserve and claim" do
    dispatch = resident_dispatch
    @agent.update!(paused: true)
    assert_no_enqueued_jobs { MessageDispatchJob.perform_now(dispatch) }
    assert_equal "author_paused", dispatch.reload.reason
    @agent.update!(paused: false)
    dispatch = resident_dispatch
    MessageDispatchJob.perform_now(dispatch)
    @agent.update!(active: false)
    assert_not dispatch.reload.runtime_interaction.claim_dispatch!
    assert_equal "author_unavailable", dispatch.reload.reason
  end

  test "departed guest creator cancels saved dispatch without reducing authority to key human" do
    guest = agents(:other_account_agent)
    membership = GuestMembership.create!(account: @agent.account, agent: guest, added_by: users(:user_1))
    dispatch = resident_dispatch(creator: guest)
    occurrence = dispatch.message.rhythm_occurrence
    membership.destroy!
    assert_empty dispatch.chat.reload.agents
    assert RhythmOccurrence.exists?(occurrence.id)
    assert Message.exists?(occurrence.message_id)
    assert_equal guest.name, occurrence.reload.creator_label
    assert_match "has left the conversation", dispatch.chat.messages.order(:id).last.content
    assert_no_enqueued_jobs { MessageDispatchJob.perform_now(dispatch) }
    assert_equal "author_not_member", dispatch.reload.reason
  end

  test "a new resident conversation still requires a resident under the creation context" do
    chat = Chat.new(account: @agent.account, title: "Empty", manual_responses: true)
    assert_not chat.valid?(:conversation_creation)
    assert chat.errors[:agents].present?
  end

  private

  def resident_dispatch(creator: @agent)
    rhythm = Rhythm.create!(
      account: @agent.account, creator_agent: creator, agents: [ creator ],
      title: "Resident round", opening: "My standing invitation", cadence: "daily", time_of_day: "09:00", timezone: "UTC"
    )
    rhythm.fire!(manual: true, request_key: SecureRandom.uuid).occurrence.message_dispatch
  end

end
