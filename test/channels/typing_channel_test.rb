require "test_helper"

class TypingChannelTest < ActionCable::Channel::TestCase

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = Chat.create!(account: @account)
    @stream = TypingChannel.stream_for_chat(@chat)
  end

  test "a member streams the conversation's typing" do
    stub_connection current_user: @user, current_app_session: nil, current_companion_device: nil
    subscribe chat_id: @chat.obfuscated_id

    assert subscription.confirmed?
    assert_has_stream @stream
  end

  test "refuses a conversation the person cannot see, a deleted one, and a missing one" do
    stub_connection current_user: @user, current_app_session: nil, current_companion_device: nil

    other = Chat.create!(account: accounts(:existing_user_account))
    subscribe chat_id: other.obfuscated_id
    assert subscription.rejected?

    discarded = Chat.create!(account: @account).tap(&:discard!)
    subscribe chat_id: discarded.obfuscated_id
    assert subscription.rejected?

    subscribe chat_id: "nope"
    assert subscription.rejected?
  end

  test "refuses connections that are not a person's browser" do
    stub_connection current_user: nil, current_app_session: nil, current_companion_device: nil
    subscribe chat_id: @chat.obfuscated_id
    assert subscription.rejected?

    stub_connection current_user: @user, current_app_session: Object.new, current_companion_device: nil
    subscribe chat_id: @chat.obfuscated_id
    assert subscription.rejected?
  end

  test "rebroadcasts typing and dictating with who it is, and nothing is stored" do
    stub_connection current_user: @user, current_app_session: nil, current_companion_device: nil
    subscribe chat_id: @chat.obfuscated_id
    expected_name = @user.first_name.presence || @user.display_name

    assert_no_difference -> { Message.count } do
      assert_broadcast_on(@stream, user_id: @user.obfuscated_id, name: expected_name, state: "typing") do
        perform :typing, state: "typing"
      end
      assert_broadcast_on(@stream, user_id: @user.obfuscated_id, name: expected_name, state: "dictating") do
        perform :typing, state: "dictating"
      end
    end
  end

  test "drops unknown states and fast repeats, but never a stop" do
    stub_connection current_user: @user, current_app_session: nil, current_companion_device: nil
    subscribe chat_id: @chat.obfuscated_id

    assert_no_broadcasts(@stream) { perform :typing, state: "shouting" }
    assert_broadcasts(@stream, 1) do
      perform :typing, state: "typing"
      perform :typing, state: "typing"
    end
    assert_broadcasts(@stream, 2) do
      perform :typing, state: "idle"
      perform :typing, state: "idle"
    end
  end

  test "leaving mid-sentence clears the indicator for everyone else" do
    stub_connection current_user: @user, current_app_session: nil, current_companion_device: nil
    subscribe chat_id: @chat.obfuscated_id
    perform :typing, state: "typing"

    assert_broadcast_on(@stream, user_id: @user.obfuscated_id, name: @user.first_name.presence || @user.display_name, state: "idle") do
      unsubscribe
    end
  end

  # Made private while open (#1092, Mira): someone left outside can't send a
  # name or state into it, including the idle sent on disconnect.
  test "a connection that lost the conversation can't announce, idle on disconnect included" do
    account = accounts(:team_account)
    owner = account.memberships.find_by!(role: "owner").user
    member = account.memberships.find_by!(role: "member").user
    agent = account.agents.create!(name: "Inside", runtime: "external", model_id: "openrouter/auto", system_prompt: "x")
    chat = account.chats.create_with_message!({ title: "Open", manual_responses: true },
      user: member, message_content: "hello", agent_ids: [ agent.id ], automatic_response: false)
    stream = TypingChannel.stream_for_chat(chat)

    stub_connection current_user: owner, current_app_session: nil, current_companion_device: nil
    subscribe chat_id: chat.obfuscated_id
    assert_broadcasts(stream, 1) { perform :typing, state: "typing" }

    chat.make_private!(by: member)
    assert_no_broadcasts(stream) { perform :typing, state: "dictating" }
    assert_no_broadcasts(stream) { unsubscribe }
  end

end
