require "test_helper"

# The stone and private conversations (eKmnrJ): the stone is its owner's
# delegate, so it goes where the owner can see and hears back only while the
# owner still could.
class CompanionDevicePocketPrivateTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
    @owner = users(:user_1)
    pairing, _code, secret = CompanionPairing.open!(name: "The stone", device_request_id: "stone-#{SecureRandom.hex(4)}",
      volumes: nil, kind: "pocket", capabilities: %w[mic])
    pairing.approve!(account: @account, user: @owner, agents: [ @agent ], accesses: {})
    _state, payload = CompanionPairing.claim(pairing.to_param, secret)
    @device, = CompanionEnrollmentGrant.enroll!(payload["enrollment_token"], payload["device_request_id"])
    assert @device.change_capture!(capability: "mic", enabled: true, actor: @owner)
    @device.update!(connection_epoch: "epoch-1")
    @first_chat = @device.chat

    # Someone else, not a member here: enough to stand outside a chat.
    @other = User.create!(email_address: "other-#{SecureRandom.hex(4)}@example.com", password: "password123")
  end

  def submit(text = "hello from the stone")
    @device.post_pocket_submission!(media_kind: "voice", content: text, client_message_id: "pocket:#{@device.to_param}:#{SecureRandom.hex(4)}")
  end

  def reply_to(message, text = "hello back")
    dispatch = MessageDispatch.find_by(message_id: message.id) ||
      MessageDispatch.accept!(message: message, target_agent_ids: [ @agent.id ], kind: "automatic")
    interaction = AgentRuntimeInteraction.create!(agent: @agent, chat: message.chat, trigger_kind: "wake",
      message_dispatch: dispatch, started_at: Time.current, last_included_message_id: message.id, shown_message_ids: [ message.id ])
    message.chat.messages.create!(role: "assistant", agent: @agent, content: text, runtime_interaction: interaction)
  end

  def replies
    broadcasts(CompanionChannel.broadcasting_for(@device)).map { |b| JSON.parse(b) }.select { |p| p["type"] == "reply" }
  end

  test "the owner starts a new private conversation for the stone and it talks there" do
    chat = @device.start_pocket_conversation!(title: "Just us", private: true, actor: @owner)

    assert chat.private?
    assert_equal chat, @device.reload.chat
    assert_equal [ @agent.id ], chat.agent_ids
    assert chat.visible_to?(@owner)
    refute chat.visible_to?(@other)
    assert submit.created?
    assert_equal chat.id, @device.reload.chat.messages.last.chat_id
    assert AuditLog.exists?(auditable: @device, action: "companion.device.retargeted")
  end

  test "only the owner can move it, and only to a conversation they can see that seats its resident" do
    assert_raises(CompanionDevice::Pocket::NotOwner) { @device.retarget_pocket!(chat: @first_chat, actor: @other) }

    theirs = @account.chats.create_with_message!({ title: "Theirs", private: true, manual_responses: true },
      agent_ids: [ @agent.id ], automatic_response: false)
    ChatParticipant.record!(chat: theirs, user: @other, source: "creator")
    error = assert_raises(CompanionDevice::Pocket::Refused) { @device.retarget_pocket!(chat: theirs, actor: @owner) }
    assert_equal "not_found", error.code

    other_agent = @account.agents.create!(name: "Someone", runtime: "external", model_id: "openrouter/auto", system_prompt: "x")
    without = @account.chats.create_with_message!({ title: "Without", manual_responses: true },
      user: @owner, agent_ids: [ other_agent.id ], automatic_response: false)
    error = assert_raises(CompanionDevice::Pocket::Refused) { @device.retarget_pocket!(chat: without, actor: @owner) }
    assert_equal "resident_not_in_conversation", error.code
    assert_equal @first_chat, @device.reload.chat
  end

  test "a reply still on its way after a switch stays in the old room" do
    clip = submit.message
    @device.start_pocket_conversation!(title: "New", private: true, actor: @owner)

    reply_to(clip)
    assert_empty replies
    assert_nil @device.reload.pocket_open_message_id
  end

  test "the stone hears back only while its owner can still read the room" do
    chat = @device.start_pocket_conversation!(title: "Just us", private: true, actor: @owner)
    clip = submit.message
    # The owner's place is gone while the reply is pending.
    chat.chat_participants.where(user: @owner).delete_all

    reply_to(clip)
    assert_empty replies
    error = assert_raises(CompanionDevice::Pocket::Refused) { submit }
    assert_equal "unauthorized", error.code
  end

  test "a clip whose upload began before a switch is refused, not posted in the new room" do
    @device.pocket_intake_chat_id = @device.chat_id
    @device.start_pocket_conversation!(title: "New", private: true, actor: @owner)

    error = assert_raises(CompanionDevice::Pocket::Refused) { submit }
    assert_equal "retargeted", error.code
    assert_empty @device.reload.chat.messages.where(companion_device_id: @device.id)
  end

  test "once the owner loses the room, no reply or voice is reachable, and retarget drops what was queued" do
    chat = @device.start_pocket_conversation!(title: "Just us", private: true, actor: @owner)
    clip = submit.message
    reply = reply_to(clip)
    assert @device.reload.pocket_reply(reply.to_param), "the reply is current before access changes"

    chat.chat_participants.where(user: @owner).delete_all
    assert_nil @device.reload.pocket_reply(reply.to_param)
    assert_empty @device.pocket_audio_payloads("epoch-1")

    ChatParticipant.record!(chat: chat, user: @owner, source: "creator")
    assert @device.reload.pocket_reply(reply.to_param)
    @device.retarget_pocket!(chat: @first_chat, actor: @owner)
    assert_nil @device.reload.pocket_reply(reply.to_param)
  end

end
