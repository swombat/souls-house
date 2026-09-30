require "test_helper"
require "support/app_oauth_test_helper"

# #94 B, step 7: authority is *current* confirmed membership, checked on every
# request. One live token first proves it can reach the team conversation, then
# loses membership one of three ways, and every account- or conversation-scoped
# route must answer 404 with nothing written. The route list is checked against
# the router, so a new app route can't slip in unswept.
class Api::App::V1::MembershipSweepTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper

  # Routes that name no account or conversation: the token alone is their authority.
  UNSCOPED = [
    "GET /api/app/v1/session", "DELETE /api/app/v1/session",
    "POST /api/app/v1/cable_ticket", "GET /api/app/v1/accounts"
  ].freeze

  LOSSES = {
    "membership removed" => ->(membership, _account) { membership.destroy! },
    "membership unconfirmed" => ->(membership, _account) { membership.update!(confirmed_at: nil) },
    "account disabled" => ->(_membership, account) { account.disable! }
  }.freeze

  setup do
    @user = users(:existing_user)
    @team = accounts(:team_account)
    @membership = memberships(:team_member)
    @client = create_app_client
    @tokens = sign_in_device
    @chat = @team.chats.create!(model_id: "openrouter/auto", title: "Team")
    @message = @chat.messages.create!(role: "user", user: @user, content: "mine", client_message_id: "c-1", submission_digest: "d")
  end

  test "every app route is either swept here or deliberately unscoped" do
    app_routes = Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      "#{route.verb} #{path}" if path.start_with?("/api/app/v1/")
    end
    swept = requests.map { |verb, _path, _params, pattern| "#{verb.to_s.upcase} #{pattern}" }
    assert_equal app_routes.sort, (swept + UNSCOPED).sort
  end

  test "the token reaches the team conversation before the loss" do
    get "/api/app/v1/conversations/#{@chat.to_param}/changes", params: { since: 0 }, headers: bearer(@tokens)
    assert_response :success
    assert_equal [ @message.to_param ], response.parsed_body["changes"].map { |m| m["id"] }
  end

  LOSSES.each do |loss, apply|
    test "after #{loss}, every scoped route is 404 and writes nothing" do
      apply.call(@membership, @team)
      before = snapshot

      requests.each do |verb, path, params, pattern|
        send(verb, path, params: params, headers: bearer(@tokens), as: (:json unless verb == :get))
        assert_response :not_found, "#{verb.upcase} #{pattern} after #{loss}"
        assert_equal "not_found", response.parsed_body.dig("error", "code"), "#{verb.upcase} #{pattern}"
      end

      assert_equal before, snapshot, "a route wrote after #{loss}"
      get "/api/app/v1/accounts", headers: bearer(@tokens)
      assert_response :success
      assert_not_includes response.parsed_body["accounts"].map { |a| a["id"] }, @team.to_param
    end
  end

  private

  # [verb, concrete path, params, router pattern]
  def requests
    a = @team.to_param
    c = @chat.to_param
    m = @message.to_param
    [
      [ :get, "/api/app/v1/accounts/#{a}/conversations", {}, "/api/app/v1/accounts/:account_id/conversations" ],
      [ :post, "/api/app/v1/accounts/#{a}/conversations", { client_conversation_id: "k-1", title: "New" }, "/api/app/v1/accounts/:account_id/conversations" ],
      [ :post, "/api/app/v1/conversations/#{c}/invoke", { client_invocation_id: "i-1" }, "/api/app/v1/conversations/:id/invoke" ],
      [ :get, "/api/app/v1/conversations/#{c}/activity", {}, "/api/app/v1/conversations/:id/activity" ],
      [ :get, "/api/app/v1/conversations/#{c}/messages", {}, "/api/app/v1/conversations/:conversation_id/messages" ],
      [ :post, "/api/app/v1/conversations/#{c}/messages", { client_message_id: "c-2", content: "hi" }, "/api/app/v1/conversations/:conversation_id/messages" ],
      [ :patch, "/api/app/v1/conversations/#{c}/messages/#{m}", { content: "edited" }, "/api/app/v1/conversations/:conversation_id/messages/:id" ],
      [ :put, "/api/app/v1/conversations/#{c}/messages/#{m}", { content: "edited" }, "/api/app/v1/conversations/:conversation_id/messages/:id" ],
      [ :delete, "/api/app/v1/conversations/#{c}/messages/#{m}", {}, "/api/app/v1/conversations/:conversation_id/messages/:id" ],
      [ :get, "/api/app/v1/conversations/#{c}/messages/#{m}/dispatch", {}, "/api/app/v1/conversations/:conversation_id/messages/:id/dispatch" ],
      [ :get, "/api/app/v1/conversations/#{c}/messages/#{m}/attachments/1", {}, "/api/app/v1/conversations/:conversation_id/messages/:message_id/attachments/:id" ],
      [ :post, "/api/app/v1/conversations/#{c}/uploads", { filename: "a.png", byte_size: 10, checksum: "x", content_type: "image/png" }, "/api/app/v1/conversations/:conversation_id/uploads" ],
      [ :get, "/api/app/v1/conversations/#{c}/changes", { since: 0 }, "/api/app/v1/conversations/:conversation_id/changes" ]
    ]
  end

  def snapshot
    @message.reload
    {
      chats: Chat.count, messages: Message.with_discarded.count, blobs: ActiveStorage::Blob.count,
      dispatches: MessageDispatch.count, audits: AuditLog.count,
      message: [ @message.content, @message.discarded_at, @message.revision ], revision: @chat.reload.message_revision
    }
  end

end
