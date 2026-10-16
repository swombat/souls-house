require "test_helper"

class GuestDirectoryChannelTest < ActionCable::Channel::TestCase

  tests SyncChannel

  test "confirmed member reads only the narrow account stream" do
    stub_connection current_user: users(:user_1), current_app_session: nil
    subscribe model: "GuestDirectory", id: accounts(:team_account).to_param
    assert subscription.confirmed?
    assert_equal [ "GuestDirectory:#{accounts(:team_account).to_param}" ], subscription.streams
  end

  test "site administrator retains read access to a specific account" do
    stub_connection current_user: users(:site_admin_user), current_app_session: nil
    subscribe model: "GuestDirectory", id: accounts(:team_account).to_param
    assert subscription.confirmed?
    assert_equal [ "GuestDirectory:#{accounts(:team_account).to_param}" ], subscription.streams
  end

  test "foreign account is denied" do
    stub_connection current_user: users(:regular_user), current_app_session: nil
    subscribe model: "GuestDirectory", id: accounts(:team_account).to_param
    assert subscription.rejected?
    assert_no_streams
  end

  test "pending membership is denied" do
    stub_connection current_user: users(:unconfirmed_user), current_app_session: nil
    subscribe model: "GuestDirectory", id: accounts(:another_team).to_param
    assert subscription.rejected?
    assert_no_streams
  end

  test "unauthenticated user is denied" do
    stub_connection current_user: nil, current_app_session: nil
    subscribe model: "GuestDirectory", id: accounts(:team_account).to_param
    assert subscription.rejected?
    assert_no_streams
  end

  test "native app connection is denied" do
    stub_connection current_user: users(:user_1), current_app_session: Object.new
    subscribe model: "GuestDirectory", id: accounts(:team_account).to_param
    assert subscription.rejected?
    assert_no_streams
  end

  test "all is denied even to site administrators" do
    stub_connection current_user: users(:site_admin_user), current_app_session: nil
    subscribe model: "GuestDirectory", id: "all"
    assert subscription.rejected?
    assert_no_streams
  end

  test "collections are denied" do
    stub_connection current_user: users(:user_1), current_app_session: nil
    subscribe model: "GuestDirectory", id: "#{accounts(:team_account).to_param}:agents"
    assert subscription.rejected?
    assert_no_streams
  end

  test "accepted guest does not grant its receiving members home streams" do
    receiving = accounts(:team_account)
    agent = agents(:research_assistant)
    receiving.guest_memberships.create!(agent: agent, added_by: users(:user_1))
    stub_connection current_user: users(:existing_user), current_app_session: nil
    subscribe model: "GuestDirectory", id: agent.account.to_param
    assert subscription.rejected?
    assert_no_streams
  end

end
