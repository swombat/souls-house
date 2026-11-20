require "test_helper"

# A pocket device (YZWBVe): pairing binds it to one resident and a new
# conversation, capture is the owner's switch, and only the reply to its own
# clip goes back down.
class CompanionDevicePocketTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

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
  def reply_to(message, text = "hello back", agent: @agent)
    dispatch = MessageDispatch.find_by(message_id: message.id) ||
      MessageDispatch.accept!(message: message, target_agent_ids: [ agent.id ], kind: "automatic")
    interaction = AgentRuntimeInteraction.create!(agent: agent, chat: message.chat, trigger_kind: "wake",
      message_dispatch: dispatch, started_at: Time.current)
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

  test "a second clip while one is open is refused" do
    enable_mic
    submit
    error = assert_raises(CompanionDevice::Pocket::Refused) { submit("again") }
    assert_equal "awaiting_reply", error.code
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
    assert_equal({ "type" => "reply", "submission_id" => message.to_param, "message_id" => reply.to_param,
      "text" => "hello back", "epoch" => "epoch-1" }, payload)
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
