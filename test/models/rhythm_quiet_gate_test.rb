require "test_helper"

class RhythmQuietGateTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @peer = agents(:code_reviewer)
    @account = @agent.account
    @now = Time.current.change(usec: 0)
    @rhythm = Rhythm.create!(
      account: @account, creator: @user, title: "Night triage", opening: "Anything new?",
      agents: [ @agent ], cadence: "daily", time_of_day: "03:00", timezone: "UTC",
      next_run_at: @now - 1.minute, quiet_gate: true
    )
    @room_chat = @account.chats.create!(title: "Shared", manual_responses: true, agents: [ @agent, @peer ],
      model_id: "openrouter/auto")
  end

  # Each tick is the next daily slot; messages default to just before it.
  def tick
    @day = (@day || -1) + 1
    at = @now + @day.days
    @rhythm.update_column(:next_run_at, at - 1.minute)
    @rhythm.fire!(now: at)
  end

  def next_tick_at = @now + ((@day || -1) + 1).days

  def post(chat, at: next_tick_at - 10.minutes, **attributes)
    attributes = { role: "user", user: @user, content: "news #{SecureRandom.hex(4)}" }.merge(attributes)
    chat.messages.create!(**attributes, created_at: at, suppress_automatic_dispatch: true)
  end

  # The first run fires (no watermark yet) and sets the baseline.
  def first_run!
    result = tick
    assert_equal :created, result.status
    result
  end

  test "first run fires and records a watermark" do
    first_run!
    assert @rhythm.reload.quiet_watermark_message_id
  end

  test "a quiet slot is skipped with no room, message, dispatch or wake, and the schedule moves on" do
    first_run!
    result = nil
    assert_no_difference [ "Chat.count", "Message.count", "MessageDispatch.count", "RhythmOccurrence.count" ] do
      assert_no_enqueued_jobs do
        result = tick
      end
    end
    assert_equal :quiet, result.status
    @rhythm.reload
    assert_equal "skipped_quiet", @rhythm.last_skip_reason
    assert_equal @now + 1.day, @rhythm.last_skipped_at
    assert @rhythm.next_run_at > @now + 1.day
    assert_equal "nothing new had arrived since its last run",
      RhythmPresentation.skip_explanation(@rhythm.last_skip_reason)
  end

  test "a person's message in a readable conversation fires the next slot" do
    first_run!
    post(@room_chat)
    assert_equal :created, tick.status
    assert_nil @rhythm.reload.last_skip_reason
  end

  test "another resident's message counts; the seated resident's own does not" do
    first_run!
    post(@room_chat, role: "assistant", user: nil, agent: @agent)
    assert_equal :quiet, tick.status

    post(@room_chat, role: "assistant", user: nil, agent: @peer)
    assert_equal :created, tick.status
  end

  test "messages in the rhythm's own occurrence conversations never count" do
    occurrence = first_run!.occurrence
    post(occurrence.chat)
    post(occurrence.chat, role: "assistant", user: nil, agent: @peer)
    assert_equal :quiet, tick.status
  end

  test "discarded and working-progress messages do not count" do
    first_run!
    post(@room_chat, discarded_at: @now)
    post(@room_chat, role: "assistant", user: nil, agent: @peer, progress_message: true)
    assert_equal :quiet, tick.status
  end

  test "a blank or still-streaming resident reply does not count until it completes" do
    first_run!
    post(@room_chat, role: "assistant", user: nil, agent: @peer, content: "")
    post(@room_chat, role: "assistant", user: nil, agent: @peer, content: "half a sentence", streaming: true)
    assert_equal :quiet, tick.status
  end

  test "an attachment-only resident reply counts" do
    first_run!
    reply = post(@room_chat, role: "assistant", user: nil, agent: @peer, content: "")
    reply.attachments.attach(io: file_fixture("test.txt").open, filename: "note.txt", content_type: "text/plain")
    assert_equal :created, tick.status
  end

  test "a reply unfinished across a check counts when it completes, though its id is old" do
    first_run!
    # Inserted well before the next check, so it is past SETTLE, but still
    # streaming: the quiet check must not move the watermark above it.
    reply = post(@room_chat, role: "assistant", user: nil, agent: @peer, content: "", streaming: true,
      at: next_tick_at - 1.hour)
    assert_equal :quiet, tick.status
    assert_operator @rhythm.reload.quiet_watermark_message_id, :<, reply.id
    reply.update_columns(content: "the finished answer", streaming: false)
    assert_equal :created, tick.status
  end

  test "a reply left unfinished past the hold stops holding the watermark" do
    first_run!
    stuck = post(@room_chat, role: "assistant", user: nil, agent: @peer, content: "", streaming: true,
      at: next_tick_at - Rhythm::QuietGate::UNFINISHED_HOLD - 1.minute)
    assert_equal :quiet, tick.status
    assert_operator @rhythm.reload.quiet_watermark_message_id, :>=, stuck.id
  end

  test "activity in a conversation not every seated resident can read never wakes the group" do
    @rhythm.update!(agents: [ @agent, @peer ])
    first_run!
    only_one = @account.chats.create!(title: "Private to one", manual_responses: true, agents: [ @agent ],
      model_id: "openrouter/auto")
    post(only_one)
    assert_equal :quiet, tick.status

    post(@room_chat)
    assert_equal :created, tick.status
  end

  test "a conversation in another account never counts" do
    first_run!
    other = agents(:other_account_agent)
    elsewhere = other.account.chats.create!(title: "Elsewhere", manual_responses: true, agents: [ other ],
      model_id: "openrouter/auto")
    post(elsewhere, user: nil, role: "assistant", agent: other)
    assert_equal :quiet, tick.status
  end

  test "narrowed rooms only count activity there, and only this account's rooms are accepted" do
    room = @account.rooms.create!(name: "Triage")
    @rhythm.update!(Rhythm.public_room_attributes(quiet_gate_room_ids: [ room.to_param ]))
    assert_equal [ room.id ], @rhythm.reload.quiet_gate_room_ids
    first_run!
    post(@room_chat)
    assert_equal :quiet, tick.status

    in_room = @account.chats.create!(title: "In room", manual_responses: true, agents: [ @agent ], room: room,
      model_id: "openrouter/auto")
    post(in_room)
    assert_equal :created, tick.status

    @rhythm.quiet_gate_room_public_ids = [ "zzzzzz" ]
    assert_not @rhythm.valid?
    assert @rhythm.errors[:quiet_gate_room_ids].present?
  end

  test "a manual start always runs, even when nothing is new" do
    first_run!
    result = @rhythm.fire!(now: @now + 1.hour, manual: true, request_key: "by-hand")
    assert_equal :created, result.status
  end

  test "a manual start leaves the scheduled baseline, so earlier news still wakes the next slot" do
    first_run!
    baseline = @rhythm.reload.quiet_watermark_message_id
    post(@room_chat, at: @now + 1.hour)
    assert_equal :created, @rhythm.fire!(now: @now + 2.hours, manual: true, request_key: "by-hand").status
    assert_equal baseline, @rhythm.reload.quiet_watermark_message_id
    assert_equal :created, tick.status
  end

  test "messages posted while an occurrence runs are counted at the next check" do
    first_run!
    # Posted after the fire, while the run is going: above the watermark.
    post(@room_chat, at: @now + 30.seconds)
    assert_equal :created, tick.status
  end

  test "a lower-id message stamped after a higher one is not lost below the watermark" do
    first_run!
    # Two messages land after the run: the lower id carries the later stamp, as
    # a slower insert would. At the next check only the higher one has settled.
    late = post(@room_chat, at: next_tick_at - 1.minute, role: "assistant", user: nil, agent: @agent)
    settled = post(@room_chat, at: next_tick_at - 10.minutes, role: "assistant", user: nil, agent: @agent)
    assert late.id < settled.id
    # Both are the seated resident's own, so the slot is quiet; the watermark
    # must still stop below the unsettled lower id.
    assert_equal :quiet, tick.status
    assert_operator @rhythm.reload.quiet_watermark_message_id, :<, late.id
  end

  test "quiet skips keep the baseline: an observed message is not counted again" do
    first_run!
    3.times { assert_equal :quiet, tick.status }
    post(@room_chat)
    assert_equal :created, tick.status
    assert_equal :quiet, tick.status
  end

  test "switching the gate off clears the watermark, and off means every slot fires" do
    first_run!
    @rhythm.update!(quiet_gate: false)
    assert_nil @rhythm.reload.quiet_watermark_message_id
    assert_equal :created, tick.status
  end

  test "a paused resident is reported as the reason, not quiet" do
    first_run!
    @agent.update!(paused: true)
    result = tick
    assert_equal :unavailable, result.status
    assert_equal "resident_paused: #{@agent.name}", @rhythm.reload.last_skip_reason
  end

end
