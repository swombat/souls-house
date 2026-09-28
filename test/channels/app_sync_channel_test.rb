require "test_helper"

# #94 B, step 6: the app's chat stream has the HTTP API's authority, carries
# invalidations only, and loses its subscription when that authority goes.
class AppSyncChannelTest < ActionCable::Channel::TestCase

  setup do
    @user = User.create!(email_address: "cable#{SecureRandom.hex(4)}@example.com", password: "password123")
    @client = Doorkeeper::Application.create!(name: "App", uid: "sync-test", redirect_uri: "https://souls.house/cb", scopes: "chat", confidential: false)
    @app_session = AppSession.create!(user: @user, oauth_application: @client)
    @team = Account.create!(name: "Team", account_type: :team)
    @membership = Membership.create!(account: @team, user: @user, role: "member", confirmed_at: Time.current)
    @chat = Chat.create!(account: @team)
    stub_connection current_user: @user, current_app_session: @app_session
    @closes = []
    closes = @closes
    connection.define_singleton_method(:close) { |**options| closes << options }
  end

  test "a device with confirmed membership streams the conversation's invalidations" do
    subscribe conversation_id: @chat.to_param

    assert subscription.confirmed?
    assert_has_stream Message::Revisioned.stream_name(@chat.id)
  end

  test "what the stream carries is an invalidation, never content" do
    subscribe conversation_id: @chat.to_param
    @chat.messages.create!(user: @user, role: "user", content: "a secret")

    payloads = broadcasts(Message::Revisioned.stream_name(@chat.id)).map { |raw| JSON.parse(raw) }
    assert_equal [ { "type" => "changed", "conversation_id" => @chat.to_param, "latest_revision" => 1 } ], payloads
  end

  test "refuses what the HTTP API would refuse" do
    other = Chat.create!(account: Account.create!(name: "Not mine", account_type: :team))
    discarded = Chat.create!(account: @team).tap(&:discard!)

    [ other.to_param, discarded.to_param, "not-an-id", nil ].each do |id|
      subscribe conversation_id: id
      assert subscription.rejected?, "expected #{id.inspect} to be refused"
    end
  end

  test "unconfirmed membership and a disabled account are refused" do
    @membership.update_column(:confirmed_at, nil)
    subscribe conversation_id: @chat.to_param
    assert subscription.rejected?

    @membership.update_column(:confirmed_at, Time.current)
    @team.update_column(:disabled_at, Time.current)
    subscribe conversation_id: @chat.to_param
    assert subscription.rejected?
  end

  test "site admin widens nothing" do
    admin = users(:site_admin_user)
    assert admin.site_admin
    stub_connection current_user: admin, current_app_session: AppSession.create!(user: admin, oauth_application: @client)

    subscribe conversation_id: @chat.to_param
    assert subscription.rejected?
  end

  test "a revoked device session is refused" do
    @app_session.update_column(:revoked_at, Time.current)
    subscribe conversation_id: @chat.to_param
    assert subscription.rejected?
  end

  test "a web cookie connection can't subscribe" do
    stub_connection current_user: @user, current_app_session: nil
    subscribe conversation_id: @chat.to_param
    assert subscription.rejected?
  end

  test "the recheck ends a subscription whose session was revoked, without reconnecting" do
    subscribe conversation_id: @chat.to_param
    @app_session.update_column(:revoked_at, Time.current) # as if the disconnect broadcast was missed

    subscription.send(:recheck_authority)

    assert_no_streams
    assert_equal [ { reason: "unauthorized", reconnect: false } ], @closes
  end

  test "the recheck ends a subscription whose membership was lost; the device may reconnect" do
    subscribe conversation_id: @chat.to_param
    @membership.delete

    subscription.send(:recheck_authority)

    assert_no_streams
    assert_equal [ { reason: "unauthorized", reconnect: true } ], @closes
  end

  test "the recheck leaves an authorised subscription alone" do
    subscribe conversation_id: @chat.to_param
    subscription.send(:recheck_authority)

    assert_has_stream Message::Revisioned.stream_name(@chat.id)
    assert_empty @closes
  end

end
