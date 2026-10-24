require "test_helper"

class TelegramPresentationChannelTest < ActionCable::Channel::TestCase

  tests SyncChannel

  test "member may subscribe only to an accessible resident's content-free hint" do
    stub_connection current_user: users(:user_1), current_app_session: nil
    agent = agents(:research_assistant)
    subscribe model: "TelegramPresentation", id: agent.to_param
    assert subscription.confirmed?
    assert_equal [ "TelegramPresentation:#{agent.to_param}" ], subscription.streams
  end

  test "outsider anonymous native all and collection requests are rejected" do
    agent = agents(:research_assistant)
    [
      [ users(:regular_user), agent.to_param, nil ],
      [ nil, agent.to_param, nil ],
      [ users(:user_1), agent.to_param, Object.new ],
      [ users(:site_admin_user), "all", nil ],
      [ users(:user_1), "#{agent.to_param}:telegram_subscriptions", nil ]
    ].each do |user, id, native|
      stub_connection current_user: user, current_app_session: native
      subscribe model: "TelegramPresentation", id:, current_app_session: native
      assert subscription.rejected?
      assert_no_streams
    end
  end

end
