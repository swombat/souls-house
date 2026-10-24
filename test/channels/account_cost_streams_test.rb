require "test_helper"

class AccountCostStreamsTest < ActionCable::Channel::TestCase

  tests SyncChannel

  %w[HomeResidentRoster AccountCostActivity].each do |model|
    [ :user_1, :site_admin_user ].each do |viewer|
      test "#{model} allows authorized account viewer #{viewer}" do
        account = accounts(:personal_account)
        stub_connection current_user: users(viewer), current_app_session: nil
        subscribe model: model, id: account.to_param
        assert subscription.confirmed?
        assert_equal [ "#{model}:#{account.to_param}" ], subscription.streams
      end
    end

    test "#{model} allows confirmed member" do
      account = memberships(:team_member).account
      stub_connection current_user: memberships(:team_member).user, current_app_session: nil
      subscribe model: model, id: account.to_param
      assert subscription.confirmed?
      assert_equal [ "#{model}:#{account.to_param}" ], subscription.streams
    end

    test "#{model} rejects foreign account" do
      stub_connection current_user: users(:user_1), current_app_session: nil
      subscribe model: model, id: accounts(:existing_user_account).to_param
      assert subscription.rejected?
      assert_no_streams
    end

    test "#{model} rejects pending membership" do
      stub_connection current_user: users(:unconfirmed_user), current_app_session: nil
      subscribe model: model, id: accounts(:another_team).to_param
      assert subscription.rejected?
      assert_no_streams
    end

    [ "all", "collection", "agent", "anonymous", "native" ].each do |target|
      test "#{model} rejects #{target} shortcut" do
        user = users(:site_admin_user)
        app_session = nil
        if target == "native"
          client = Doorkeeper::Application.create!(name: "Cost test", uid: "#{model}-native",
            redirect_uri: "https://example.test/cb", scopes: "chat", confidential: false)
          app_session = AppSession.create!(user: user, oauth_application: client)
        end
        stub_connection current_user: target == "anonymous" ? nil : user, current_app_session: app_session
        id = case target
        when "all" then "all"
        when "collection" then "#{accounts(:personal_account).to_param}:agents"
        when "agent" then agents(:research_assistant).to_param
        else accounts(:personal_account).to_param
        end
        subscribe model: model, id: id
        assert subscription.rejected?
        assert_no_streams
      end
    end
  end

end
