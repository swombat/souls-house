require "test_helper"

# A private conversation's web streams are rechecked at delivery (eKmnrJ,
# Mira #1089), not only at subscribe.
class SyncChannelPrivateTest < ActionCable::Channel::TestCase

  tests SyncChannel

  setup do
    @account = accounts(:team_account)
    @creator = @account.memberships.find_by!(role: "member").user
    @admin = @account.memberships.find_by!(role: "owner").user
    @agent = @account.agents.create!(name: "Inside", runtime: "external", model_id: "openrouter/auto", system_prompt: "x")
    @chat = @account.chats.create_with_message!({ title: "Secret", private: true, manual_responses: true },
      user: @creator, agent_ids: [ @agent.id ], automatic_response: false)
  end

  test "an outsider can't subscribe, site admin or not" do
    @admin.update_columns(is_site_admin: true)
    stub_connection current_user: @admin.reload, current_app_session: nil
    subscribe model: "Chat", id: @chat.obfuscated_id
    assert subscription.rejected?
  end

  test "an open subscription stops delivering once the person loses the account" do
    stub_connection current_user: @creator, current_app_session: nil
    subscribe model: "Chat", id: @chat.obfuscated_id
    assert subscription.confirmed?
    assert subscription.send(:private_chat_still_visible?, @chat.id)

    @account.memberships.find_by!(user: @creator).update_columns(confirmed_at: nil)
    travel SyncChannel::PRIVATE_RECHECK + 1.second do
      refute subscription.send(:private_chat_still_visible?, @chat.id)
    end
  end

end
