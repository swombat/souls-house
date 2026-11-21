require "test_helper"

# A pocket device (YZWBVe): pairing binds it to one resident and a new
# conversation, capture is the owner's switch, and only the reply to its own
# clip goes back down.
class CompanionDevicePocketTest < ActiveSupport::TestCase

  include ActionCable::TestHelper
  include ActiveJob::TestHelper

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
    @owner = users(:user_1)
    @device = pair_pocket
  end

  def pair_pocket(name: "The stone", capabilities: %w[mic camera], user: @owner)
    pairing, _code, secret = CompanionPairing.open!(name: name, device_request_id: "stone-#{SecureRandom.hex(4)}",
      volumes: nil, kind: "pocket", capabilities: capabilities)
    pairing.approve!(account: @account, user: user, agents: [ @agent ], accesses: {})
    _state, payload = CompanionPairing.claim(pairing.to_param, secret)
    device, = CompanionEnrollmentGrant.enroll!(payload["enrollment_token"], payload["device_request_id"])
    device
  end

  def submit(text = "hello from the stone", request_id: SecureRandom.hex(4))
    @device.post_pocket_submission!(media_kind: "voice", content: text, client_message_id: "pocket:#{@device.to_param}:#{request_id}")
  end

  # The run the submission's message woke, and a reply written by it.
  # shown: the messages whose ids the run's request carried.
  def reply_to(message, text = "hello back", agent: @agent, shown: [ message ])
    dispatch = MessageDispatch.find_by(message_id: message.id) ||
      MessageDispatch.accept!(message: message, target_agent_ids: [ agent.id ], kind: "automatic")
    interaction = AgentRuntimeInteraction.create!(agent: agent, chat: message.chat, trigger_kind: "wake",
      message_dispatch: dispatch, started_at: Time.current, last_included_message_id: shown.map(&:id).max,
      shown_message_ids: shown.map(&:id))
    message.chat.messages.create!(role: "assistant", agent: agent, content: text, runtime_interaction: interaction)
  end

  def unrelated_run_reply(text = "something else")
    interaction = AgentRuntimeInteraction.create!(agent: @agent, chat: @device.chat, trigger_kind: "wake", started_at: Time.current)
    @device.chat.messages.create!(role: "assistant", agent: @agent, content: text, runtime_interaction: interaction)
  end

  # A live cable: what goes down is stamped with its epoch.
  def enable_mic
    assert @device.change_capture!(capability: "mic", enabled: true, actor: @owner)
    @device.update!(connection_epoch: "epoch-1")
  end

  def payloads
    broadcasts(CompanionChannel.broadcasting_for(@device)).map { |b| JSON.parse(b) }
  end

  test "pairing binds kind, one resident and a new conversation with only that resident" do
    assert @device.pocket?
    assert_equal %w[mic camera], @device.offered_capabilities
    assert_equal [ @agent.id ], @device.chat.agent_ids
    assert_equal "The stone", @device.chat.title
    assert_equal [ { "id" => @agent.to_param, "volumes" => [], "execute" => false } ], @device.policy["residents"]
    assert_not @device.mic_enabled
    assert_not @device.camera_enabled
    assert_equal @owner.id, @device.owner_user_id
  end

  test "the binding on the grant can't be changed after approval" do
    grant = @device.companion_enrollment_grant
    other = @account.chats.create!(title: "Elsewhere", model_id: "openrouter/auto")
    assert_raises(ActiveRecord::ReadonlyAttributeError) { grant.update!(chat_id: other.id) }
    assert_raises(ActiveRecord::ReadonlyAttributeError) { grant.update!(kind: "computer") }
  end

  test "a pocket pairing must choose exactly one resident and offers no volumes" do
    pairing, = CompanionPairing.open!(name: "Stone", device_request_id: "stone-x", volumes: nil, kind: "pocket",
      capabilities: %w[mic])
    assert_raises(CompanionPairing::Invalid) { pairing.approve!(account: @account, user: @owner, agents: [], accesses: {}) }
    assert_raises(CompanionPairing::Invalid) do
      CompanionPairing.open!(name: "Stone", device_request_id: "stone-y", kind: "pocket", capabilities: %w[mic],
        volumes: [ { "volume" => "v", "label" => "V", "access" => "read" } ])
    end
    [ [], %w[speaker], %w[mic mic], nil ].each do |caps|
      assert_raises(CompanionPairing::Invalid) do
        CompanionPairing.open!(name: "Stone", device_request_id: "stone-z", volumes: nil, kind: "pocket", capabilities: caps)
      end
    end
  end

  test "only the owner turns capture on; a manager can turn it off; changes are audited and pushed" do
    admin = users(:admin)
    assert_raises(CompanionDevice::Pocket::NotOwner) { @device.change_capture!(capability: "mic", enabled: true, actor: admin) }
    @device.update!(connection_epoch: "epoch-1")
    assert_broadcasts(CompanionChannel.broadcasting_for(@device), 1) { enable_mic }
    assert @device.reload.mic_enabled
    assert @device.change_capture!(capability: "mic", enabled: false, actor: admin)
    assert_not @device.reload.mic_enabled
    assert_equal [ { "type" => "consent", "mic" => true, "camera" => false, "consent_revision" => 1, "epoch" => "epoch-1" },
      { "type" => "consent", "mic" => false, "camera" => false, "consent_revision" => 2, "epoch" => "epoch-1" } ], payloads
    assert_equal 2, AuditLog.where(action: "companion.device.capture_changed", auditable: @device).count
  end

  test "a capability the device didn't offer can't be turned on" do
    @device = pair_pocket(capabilities: %w[mic])
    assert_raises(ArgumentError) { @device.change_capture!(capability: "camera", enabled: true, actor: @owner) }
  end

  test "capture off refuses before any message exists" do
    assert_no_difference -> { Message.count } do
      error = assert_raises(CompanionDevice::Pocket::Refused) { submit }
      assert_equal "consent_off", error.code
    end
  end

  test "a submission is a message from the device, owned by its owner, and opens the slot" do
    enable_mic
    result = submit
    assert result.created?
    message = result.message
    assert_equal @device, message.companion_device
    assert_equal @owner, message.user
    assert_equal "The stone", message.author_name
    assert_match "The stone (", ExternalAgentResponseRequest.speaker_for(message)
    assert_equal message.id, @device.reload.pocket_open_message_id
  end

  test "clips while one is open join the run, up to the cap" do
    enable_mic
    first = submit.message
    opened_at = @device.reload.pocket_opened_at
    travel 1.minute do
      (CompanionDevice::Pocket::MAX_QUEUED_CLIPS - 1).times { |i| assert submit("more #{i}").created? }
      assert_equal [ first.id, opened_at ], [ @device.reload.pocket_open_message_id, @device.pocket_opened_at ],
        "a later clip moves neither the anchor nor the deadline"
      error = assert_raises(CompanionDevice::Pocket::Refused) { submit("one too many") }
      assert_equal "awaiting_reply", error.code
    end
  end

  # Mira, YrBOKp: A's run is going, B and C arrive, one held wake answers
  # them. Each reply covers only the clips its run was shown.
  test "a reply covers what its run read; later clips wait for their own wake" do
    enable_mic
    a = submit("a").message
    b = submit("b").message
    c = submit("c").message
    reply_a = reply_to(a, "for a")
    down = payloads.select { |p| p["type"] == "reply" }
    assert_equal [ [ a.to_param ] ], down.map { |p| p["submission_ids"] }
    assert_equal b.id, @device.reload.pocket_open_message_id, "b and c are still waiting"
    assert_equal b.created_at.to_i, @device.pocket_opened_at.to_i, "under b's own deadline"

    # The held wake, carried on c's dispatch, was shown both b and c.
    reply_bc = reply_to(c, "for b and c", shown: [ b, c ])
    last = payloads.last
    assert_equal({ "type" => "reply", "submission_id" => c.to_param, "submission_ids" => [ b.to_param, c.to_param ],
      "message_id" => reply_bc.to_param, "text" => "for b and c", "epoch" => "epoch-1" }, last)
    assert_nil @device.reload.pocket_open_message_id
    assert_equal [ reply_bc.id, c.id ], [ @device.pocket_reply_message_id, @device.pocket_reply_submission_id ]
    assert_not_equal reply_a.id, @device.pocket_reply_message_id
  end

  test "a run whose request doesn't carry a later clip covers only the clip that woke it" do
    enable_mic
    a = submit("a").message
    b = submit("b").message
    reply_to(a, shown: [ a ])
    assert_equal [ a.to_param ], payloads.last["submission_ids"]
    assert_equal b.id, @device.reload.pocket_open_message_id
  end

  # Mira, #1083: a wake on C, with an older outstanding B that wasn't in the
  # run's input, must not mark B answered, even when the cursor is past B.
  test "an older clip the run wasn't shown ends ambiguous, never answered" do
    enable_mic
    a = submit("a").message
    reply_to(a)
    b = submit("b").message
    c = submit("c").message
    reply_c = reply_to(c, "for c", shown: [ c ])
    ambiguous, reply = payloads.last(2)
    assert_equal({ "type" => "ambiguous", "submission_id" => b.to_param, "submission_ids" => [ b.to_param ],
      "epoch" => "epoch-1" }, ambiguous)
    assert_equal [ "reply", [ c.to_param ], reply_c.to_param ], reply.values_at("type", "submission_ids", "message_id")
    assert_nil @device.reload.pocket_open_message_id, "no clip is left without an outcome"
  end

  # Mira, #1083: covering A and C but leaving B pending would bring C back
  # into the queue behind B's anchor. The waiting tail stays contiguous.
  test "a gap in what the run was shown stops coverage; the waiting tail stays contiguous" do
    enable_mic
    a = submit("a").message
    b = submit("b").message
    c = submit("c").message
    reply_to(a, shown: [ a, c ])
    assert_equal [ a.to_param ], payloads.last["submission_ids"]
    assert_equal b.id, @device.reload.pocket_open_message_id
    assert_equal [ b, c ], @device.pocket_open_clips.to_a
  end

  test "a clip quoted in the request text but not one of its rows isn't counted as read" do
    enable_mic
    b = submit("b").message
    c = submit("c").message
    dispatch = MessageDispatch.find_by(message_id: c.id) ||
      MessageDispatch.accept!(message: c, target_agent_ids: [ @agent.id ], kind: "automatic")
    interaction = AgentRuntimeInteraction.create!(agent: @agent, chat: c.chat, trigger_kind: "wake", message_dispatch: dispatch,
      started_at: Time.current, shown_message_ids: [ c.id ], request_text: "Someone quoted [#{b.obfuscated_id}] here")
    c.chat.messages.create!(role: "assistant", agent: @agent, content: "for c", runtime_interaction: interaction)
    assert_equal [ [ "ambiguous", [ b.to_param ] ], [ "reply", [ c.to_param ] ] ],
      payloads.last(2).map { |p| p.values_at("type", "submission_ids") }
  end

  # Mira, #1083: a bounded transcript can leave out the waking clip itself.
  test "a run that wasn't shown its own waking clip ends the clips ambiguous, with no reply or voice" do
    enable_mic
    b = submit("b").message
    c = submit("c").message
    reply = reply_to(c, "for c", shown: [ b ])
    assert_equal [ "ambiguous", [ b.to_param, c.to_param ] ], payloads.last.values_at("type", "submission_ids")
    assert_not_includes payloads.map { |p| p["type"] }, "reply"
    assert_nil @device.reload.pocket_open_message_id
    assert_nil @device.pocket_reply(reply.to_param)
  end

  # Mira, #1083: deploy order; an old worker writes only the single columns.
  test "a reply an old-code worker wrote after the backfill is still fetchable" do
    enable_mic
    message = submit.message
    listed = unrelated_run_reply("listed")
    late = unrelated_run_reply("written by old code")
    @device.update_columns(pocket_replies: [ { "reply_id" => listed.id, "submission_id" => message.id, "at" => 2.minutes.ago.iso8601(6) } ],
      pocket_reply_message_id: late.id, pocket_reply_submission_id: message.id, pocket_replied_at: 1.minute.ago)
    assert_equal listed, @device.reload.pocket_reply(listed.to_param)
    assert_equal late, @device.pocket_reply(late.to_param)
  end

  # Mira, #1083: the last reply from before the deploy keeps its window.
  test "the migration carries the last pre-deploy reply into the list with its own time" do
    enable_mic
    message = submit.message
    reply = unrelated_run_reply("old reply")
    replied_at = 5.minutes.ago
    @device.update_columns(pocket_reply_message_id: reply.id, pocket_reply_submission_id: message.id,
      pocket_replied_at: replied_at, pocket_replies: [])
    sql = File.read(Dir[Rails.root.join("db/migrate/20261121103000_*.rb")].first)[/UPDATE companion_devices.*?(?=\n\s*SQL)/m]
    ActiveRecord::Base.connection.execute(sql)
    assert_equal reply, @device.reload.pocket_reply(reply.to_param)
    assert_in_delta replied_at.to_f, Time.zone.parse(@device.pocket_replies.first["at"]).to_f, 0.001
    travel CompanionDevice::Pocket::AUDIO_WINDOW - 4.minutes do
      assert_nil @device.pocket_reply(reply.to_param), "the window runs from the old reply, not the deploy"
    end
  end

  test "two replies in a row both keep their voice; the later doesn't supersede the earlier" do
    speak_with_eleven_labs
    enable_mic
    a = submit("a").message
    b = submit("b").message
    reply_a, reply_b = SpeechEngine.stub(:house_eleven_labs_key, "house-key") do
      [ reply_to(a, "for a"), reply_to(b, "for b") ]
    end
    # A's voice finishes only after B's text went down.
    attach_voice(reply_a)
    CompanionDevice.announce_pocket_audio(reply_a.reload)
    audio = payloads.last
    assert_equal [ "audio", a.to_param, reply_a.to_param ], audio.values_at("type", "submission_id", "message_id")
    assert_equal reply_a, @device.reload.pocket_reply(reply_a.to_param)
    assert_equal reply_b, @device.pocket_reply(reply_b.to_param)

    attach_voice(reply_b)
    @device.update!(connection_epoch: "epoch-2")
    assert_equal [ reply_a.to_param, reply_b.to_param ], @device.pocket_audio_payloads.map { |p| p["message_id"] || p[:message_id] },
      "a reconnect gets every voice still in its window"
    travel CompanionDevice::Pocket::AUDIO_WINDOW + 1.minute do
      assert_nil @device.pocket_reply(reply_a.to_param)
    end
  end

  test "an unrelated human message in a queued run makes every outstanding clip ambiguous" do
    enable_mic
    a = submit("a").message
    b = submit("b").message
    @device.chat.messages.create!(role: "user", user: @owner, content: "and also this")
    c = submit("c").message
    reply_to(c, shown: [ a, b, c ])
    assert_not payloads.any? { |p| p["type"] == "reply" }
    assert_equal({ "type" => "ambiguous", "submission_id" => a.to_param,
      "submission_ids" => [ a, b, c ].map(&:to_param), "epoch" => "epoch-1" }, payloads.last)
    assert_nil @device.reload.pocket_open_message_id
  end

  test "clips nobody answered end as expired before the next clip opens a new run" do
    enable_mic
    a = submit("a").message
    b = submit("b").message
    travel CompanionDevice::Pocket::OPEN_WINDOW + 1.minute do
      fresh = submit("later").message
      expired = payloads.find { |p| p["type"] == "expired" }
      assert_equal [ a.to_param, b.to_param ], expired["submission_ids"]
      assert_equal fresh.id, @device.reload.pocket_open_message_id
      assert_equal %w[expired thinking], payloads.last(2).map { |p| p["type"] }
    end
  end

  test "a late reply after the deadline expires the clips instead of answering them" do
    enable_mic
    a = submit("a").message
    travel CompanionDevice::Pocket::OPEN_WINDOW + 1.minute do
      reply_to(a)
      assert_equal "expired", payloads.last["type"]
      assert_not payloads.any? { |p| p["type"] == "reply" }
    end
  end

  test "a retry with the same request id makes no second message" do
    enable_mic
    first = submit(request_id: "r1").message
    second = submit(request_id: "r1")
    assert second.duplicate?
    assert_equal first, second.message
  end

  test "the reply woken by the clip goes down and closes the slot" do
    enable_mic
    message = submit.message
    reply = nil
    assert_broadcasts(CompanionChannel.broadcasting_for(@device), 1) { reply = reply_to(message) }
    assert_nil @device.reload.pocket_open_message_id
    payload = broadcasts(CompanionChannel.broadcasting_for(@device)).map { |b| JSON.parse(b) }.last
    assert_equal({ "type" => "reply", "submission_id" => message.to_param, "submission_ids" => [ message.to_param ],
      "message_id" => reply.to_param, "text" => "hello back", "epoch" => "epoch-1" }, payload)
  end

  # The stone may speak through ElevenLabs on the house key here
  # (SpeechEngine.for_pocket), while the account's browsers stay on Phonon.
  def speak_with_eleven_labs
    Setting.instance.update!(speech_engine_scope: "account_choice")
    @account.update!(speech_engine: "phonon", eleven_labs_api_key: nil, house_eleven_labs_key: true, granted_plan: "partners")
    @agent.update_column(:voice_id, "std-aria")
  end

  def attach_voice(reply)
    reply.voice_audio.attach(io: StringIO.new("ID3"), filename: "v.mp3", content_type: "audio/mpeg",
      metadata: { "voice_digest" => reply.current_voice_digest })
  end

  test "the reply goes down at once and its voice is rendered after, then announced as audio" do
    speak_with_eleven_labs
    enable_mic
    message = submit.message
    reply = nil
    SpeechEngine.stub(:house_eleven_labs_key, "house-key") do
      reply = reply_to(message)
      assert_enqueued_with(job: GenerateVoiceJob, args: [ reply, { surface: "pocket" } ])
    end
    assert_equal %w[thinking reply], payloads.map { |p| p["type"] }, "the text never waits for the voice"
    assert_equal [ reply.id, message.id ], [ @device.reload.pocket_reply_message_id, @device.pocket_reply_submission_id ]

    attach_voice(reply)
    CompanionDevice.announce_pocket_audio(reply.reload)
    audio = payloads.last
    assert_equal({ "type" => "audio", "submission_id" => message.to_param, "message_id" => reply.to_param, "epoch" => "epoch-1" },
      audio.except("url"))
    assert_equal "http://example.com/api/v1/companion/pocket/replies/#{reply.to_param}/audio", audio["url"]
  end

  test "with ElevenLabs off on the site no voice is rendered for the stone" do
    enable_mic
    message = submit.message
    assert_no_enqueued_jobs(only: GenerateVoiceJob) { reply_to(message) }
  end

  test "the text goes down before the voice is scheduled, and a scheduling failure costs only the voice" do
    speak_with_eleven_labs
    enable_mic
    message = submit.message
    seen_at_enqueue = nil
    failing = ->(*) { seen_at_enqueue = payloads.map { |p| p["type"] }; raise "queue down" }
    SpeechEngine.stub(:house_eleven_labs_key, "house-key") do
      GenerateVoiceJob.stub(:perform_later, failing) { reply_to(message) }
    end
    assert_equal %w[thinking reply], seen_at_enqueue, "the reply was already on the cable"
    assert_equal %w[thinking reply], payloads.map { |p| p["type"] }
    assert_nil @device.reload.pocket_open_message_id
  end

  test "a Phonon account with its own key and no switch gets text only from the stone" do
    speak_with_eleven_labs
    @account.update!(house_eleven_labs_key: false, eleven_labs_api_key: "acct-key")
    enable_mic
    message = submit.message
    assert_no_enqueued_jobs(only: GenerateVoiceJob) { reply_to(message) }
    assert_equal %w[thinking reply], payloads.map { |p| p["type"] }
  end

  test "an error deciding the voice never touches the text" do
    speak_with_eleven_labs
    enable_mic
    message = submit.message
    SpeechEngine.stub(:for_pocket, ->(*) { raise "policy lookup failed" }) { reply_to(message) }
    assert_equal %w[thinking reply], payloads.map { |p| p["type"] }
    assert_nil @device.reload.pocket_open_message_id
    assert_no_enqueued_jobs(only: GenerateVoiceJob)
  end

  test "a pause ends the last reply's voice too: nothing is announced after it" do
    speak_with_eleven_labs
    enable_mic
    reply = SpeechEngine.stub(:house_eleven_labs_key, "house-key") { reply_to(submit.message) }
    @device.apply_control!("pause")
    @device.apply_control!("resume")
    @device.update!(connection_epoch: "epoch-2")
    attach_voice(reply)

    count = payloads.size
    CompanionDevice.announce_pocket_audio(reply.reload)
    assert_equal count, payloads.size
    assert_empty @device.reload.pocket_recent_replies
  end

  test "the same resident replying from an unrelated run is not delivered" do
    enable_mic
    message = submit.message
    unrelated_run_reply
    assert_nil @device.reload.pocket_open_message_id, "ambiguity closes the slot"
    payloads = broadcasts(CompanionChannel.broadcasting_for(@device)).map { |b| JSON.parse(b) }
    assert_equal "ambiguous", payloads.last["type"]
    assert_not payloads.any? { |p| p["type"] == "reply" }
    assert_equal message.to_param, payloads.last["submission_id"]
  end

  test "a human turn between the clip and the reply makes it ambiguous" do
    enable_mic
    message = submit.message
    @device.chat.messages.create!(role: "user", user: @owner, content: "and also this")
    reply_to(message)
    payloads = broadcasts(CompanionChannel.broadcasting_for(@device)).map { |b| JSON.parse(b) }
    assert_not payloads.any? { |p| p["type"] == "reply" }
  end

  test "a reply in another conversation is never delivered" do
    enable_mic
    submit
    other = @account.chats.create!(title: "Other", model_id: "openrouter/auto")
    interaction = AgentRuntimeInteraction.create!(agent: @agent, chat: other, trigger_kind: "wake", started_at: Time.current)
    other.messages.create!(role: "assistant", agent: @agent, content: "not for the stone", runtime_interaction: interaction)
    assert @device.reload.pocket_open_message_id, "the slot stays open"
  end

  test "pause or revoke drops a reply that arrives after it, and ends the clip and the epoch" do
    enable_mic
    message = submit.message
    @device.apply_control!("pause")
    assert_nil @device.reload.connection_epoch, "a pause ends the live epoch"
    assert_nil @device.pocket_open_message_id, "a pause ends the clip in flight"
    reply_to(message)
    assert_not payloads.any? { |p| p["type"] == "reply" }

    @device.apply_control!("resume")
    @device.update!(connection_epoch: "epoch-2")
    reply_to(message, "late")
    assert_not payloads.any? { |p| p["type"] == "reply" }, "resuming doesn't revive the old clip"

    @device.apply_control!("resume")
    @device.revoke!
    assert_raises(CompanionDevice::Pocket::Refused) { submit("after revoke") }
  end

  test "a reply while no cable is connected is not queued for later" do
    enable_mic
    message = submit.message
    @device.update!(connection_epoch: nil)
    reply_to(message)
    assert_not payloads.any? { |p| p["type"] == "reply" }
    assert_nil @device.reload.pocket_open_message_id
  end

  test "a held wake names the device, not its owner" do
    enable_mic
    message = submit.message
    assert_equal "The stone", message.wake_requester_name
  end

  test "a pocket can't run operations" do
    error = assert_raises(CompanionOperation::Refused) do
      CompanionOperation.start!(device: @device, agent: @agent, kind: "list", arguments: {})
    end
    assert_match "no operations", error.message
  end

end
