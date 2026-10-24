require "test_helper"

class ProviderPresentationChannelTest < ActionCable::Channel::TestCase

  tests SyncChannel

  test "member and site administrator can read only a specific authorized account" do
    [ users(:user_1), users(:site_admin_user) ].each do |user|
      stub_connection current_user: user, current_app_session: nil
      subscribe model: "ProviderPresentation", id: accounts(:team_account).to_param
      assert subscription.confirmed?
      assert_equal [ "ProviderPresentation:#{accounts(:team_account).to_param}" ], subscription.streams
      unsubscribe
    end
  end

  test "outsider unauthenticated pending native all and collection access are rejected" do
    [
      [ users(:regular_user), accounts(:team_account).to_param, nil ],
      [ nil, accounts(:team_account).to_param, nil ],
      [ users(:unconfirmed_user), accounts(:another_team).to_param, nil ],
      [ users(:user_1), accounts(:team_account).to_param, Object.new ],
      [ users(:site_admin_user), "all", nil ],
      [ users(:user_1), "#{accounts(:team_account).to_param}:agents", nil ]
    ].each do |user, id, native|
      stub_connection current_user: user, current_app_session: native
      subscribe model: "ProviderPresentation", id: id
      assert subscription.rejected?
      assert_no_streams
    end
  end

end
