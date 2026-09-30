require "test_helper"

# #94 B, step 6: revocation and membership loss drop the device's cable
# connections once the change commits.
class AppSessionCableDisconnectTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @user = User.create!(email_address: "disc#{SecureRandom.hex(4)}@example.com", password: "password123")
    @client = Doorkeeper::Application.create!(name: "App", uid: "disc-test", redirect_uri: "https://souls.house/cb", scopes: "chat", confidential: false)
    @phone = AppSession.create!(user: @user, oauth_application: @client)
    @tablet = AppSession.create!(user: @user, oauth_application: @client)
    @team = Account.create!(name: "Team", account_type: :team)
    @membership = Membership.create!(account: @team, user: @user, role: "member", confirmed_at: Time.current)
  end

  test "revoking a session disconnects that device without reconnect, after commit" do
    AppSession.transaction do
      @phone.revoke!(:user_revoked)
      assert_no_broadcasts internal(@phone)
    end

    assert_broadcast_on internal(@phone), { type: "disconnect", reconnect: false }
    assert_no_broadcasts internal(@tablet)
  end

  test "a rolled-back revocation disconnects nothing" do
    AppSession.transaction do
      @phone.revoke!(:user_revoked)
      raise ActiveRecord::Rollback
    end

    assert_no_broadcasts internal(@phone)
  end

  test "removing a membership disconnects every live device of that member" do
    @tablet.revoke!(:logout)
    clear_broadcasts
    @membership.destroy!

    assert_broadcast_on internal(@phone), { type: "disconnect", reconnect: true }
    assert_no_broadcasts internal(@tablet)
  end

  test "losing confirmation disconnects; other membership edits don't" do
    @membership.update!(role: "admin")
    assert_no_broadcasts internal(@phone)

    @membership.update!(confirmed_at: nil)
    assert_broadcast_on internal(@phone), { type: "disconnect", reconnect: true }
  end

  test "disabling an account disconnects its members" do
    @team.disable!
    assert_broadcast_on internal(@phone), { type: "disconnect", reconnect: true }
  end

  test "another user's devices are untouched" do
    other = User.create!(email_address: "other#{SecureRandom.hex(4)}@example.com", password: "password123")
    theirs = AppSession.create!(user: other, oauth_application: @client)
    @membership.destroy!

    assert_no_broadcasts internal(theirs)
  end

  private

  def internal(app_session)
    "action_cable/#{[ app_session.user.to_gid_param, app_session.to_gid_param ].sort.join(':')}"
  end

  def clear_broadcasts
    pubsub_adapter.clear
  end

end
