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

  test "an open subscription stops delivering the moment the person loses the account" do
    stub_connection current_user: @creator, current_app_session: nil
    subscribe model: "Chat", id: @chat.obfuscated_id
    assert subscription.confirmed?
    deliver = subscription.send(:private_delivery, @chat.id)

    deliver.call({ "n" => 1 })
    assert_equal [ { "n" => 1 } ], transmissions

    # Straight after the loss, with no time passing: nothing more goes down.
    @account.memberships.find_by!(user: @creator).update_columns(confirmed_at: nil)
    deliver.call({ "n" => 2 })
    assert_equal [ { "n" => 1 } ], transmissions

    # A denial is sticky for the life of the subscription.
    @account.memberships.find_by!(user: @creator).update_columns(confirmed_at: Time.current)
    deliver.call({ "n" => 3 })
    assert_equal [ { "n" => 1 } ], transmissions
  end

end
