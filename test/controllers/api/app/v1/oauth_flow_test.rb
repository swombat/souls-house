require "test_helper"
require "support/app_oauth_test_helper"

# Issue #94, PR A: the auth spike. Every case goes through Doorkeeper's real
# /oauth/authorize, /oauth/token and /oauth/revoke paths on the pinned 5.9.7,
# not helpers. The truly concurrent cases live in oauth_concurrency_test.rb.
class Api::App::V1::OauthFlowTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper

  setup do
    @user = users(:existing_user)
    @client = create_app_client
  end

  # --- authorization ---------------------------------------------------------

  test "sign in through the browser, exchange the code with PKCE, call the API" do
    tokens = sign_in_device
    assert tokens["refresh_token"].present?
    assert_equal "Bearer", tokens["token_type"]
    assert_equal "chat", tokens["scope"]

    get "/api/app/v1/session", headers: bearer(tokens)
    assert_response :success
    assert_equal @user.to_param, response.parsed_body.dig("user", "id")
    assert_equal "Pixel 9", response.parsed_body.dig("session", "device_label")
  end

  test "the client is public: it has no secret and none is needed" do
    assert_not @client.confidential?
    assert_nil @client.secret
    tokens = sign_in_device # neither the code exchange nor refresh sends a secret
    refresh(tokens)
  end

  test "secrets are stored hashed, and the rotation lookup works on the hashes" do
    verifier = SecureRandom.urlsafe_base64(48)
    code = authorize_code(challenge_for(verifier))
    assert_nil Doorkeeper::AccessGrant.find_by(token: code), "authorization codes are stored hashed"
    exchange_code(code, verifier)
    t1 = response.parsed_body

    first = Doorkeeper::AccessToken.last
    assert_not_equal t1["access_token"], first.token
    assert_not_equal t1["refresh_token"], first.refresh_token
    assert_equal first, Doorkeeper::AccessToken.by_token(t1["access_token"])

    t2 = refresh(t1)
    second = row_for(t2)
    assert_equal first.refresh_token, second.previous_refresh_token, "previous_refresh_token holds the stored (hashed) value"
    assert_not_equal t1["refresh_token"], second.previous_refresh_token
    assert_equal first, Doorkeeper::AccessToken.by_previous_refresh_token(second.previous_refresh_token)

    use(t2)
    assert first.reload.revoked?, "first use of the new access token revokes its predecessor"
    assert_equal "", second.reload.previous_refresh_token
  end

  test "an unauthenticated browser is sent to the normal login and back to the app" do
    verifier = SecureRandom.urlsafe_base64(48)
    get "/oauth/authorize", params: authorize_params(challenge_for(verifier))
    assert_redirected_to login_url

    sign_in @user
    assert_response :redirect
    assert_equal "/oauth/authorize", URI(response.location).path
    follow_redirect!
    exchange_code(code_from_callback, verifier)
    assert_response :success
  end

  test "the Inertia login form leaves the SPA for the authorize redirect" do
    get "/oauth/authorize", params: authorize_params(challenge_for("v" * 50))
    assert_redirected_to login_url

    post "/login", params: { email_address: @user.email_address, password: "password123" },
                   headers: { "X-Inertia" => "true" }
    assert_response :conflict
    assert_equal "/oauth/authorize", URI(response.headers["X-Inertia-Location"]).path
  end

  test "PKCE is required" do
    sign_in @user
    get "/oauth/authorize", params: authorize_params(nil).except(:code_challenge, :code_challenge_method)
    assert_no_code_issued
  end

  test "the plain PKCE method is refused" do
    sign_in @user
    get "/oauth/authorize", params: authorize_params("v" * 50).merge(code_challenge_method: "plain")
    assert_no_code_issued
  end

  test "a code cannot be exchanged without its verifier" do
    code = authorize_code(challenge_for("v" * 50))
    post "/oauth/token", params: { grant_type: "authorization_code", code: code, client_id: @client.uid, redirect_uri: CALLBACK }
    assert_response :bad_request
  end

  test "a wrong code verifier is refused" do
    code = authorize_code(challenge_for("right-verifier-" + "x" * 40))
    exchange_code(code, "wrong-verifier-" + "x" * 40)
    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "a callback that is not exactly the registered one is refused" do
    sign_in @user
    [ "#{CALLBACK}/x", "#{CALLBACK}?next=evil", "https://SOULS.HOUSE/app/oauth/callback", "soulshouse://callback", "" ].each do |uri|
      get "/oauth/authorize", params: authorize_params(challenge_for("v" * 50)).merge(redirect_uri: uri)
      assert_response :bad_request, "#{uri.inspect} must be refused"
      assert_nil response.location
    end
  end

  test "a bad callback is refused before any login detour" do
    get "/oauth/authorize", params: authorize_params(challenge_for("v" * 50)).merge(redirect_uri: "https://evil.example/cb")
    assert_response :bad_request
  end

  test "outside development and test, only HTTPS callbacks can be registered" do
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) do
      assert_not Doorkeeper::Application.new(name: "x", redirect_uri: "soulshouse://callback").valid?
      assert Doorkeeper::Application.new(name: "x", redirect_uri: CALLBACK).valid?
    end
  end

  test "app_session_id cannot be injected through authorize params" do
    victim = AppSession.create!(user: @user, oauth_application: @client)
    tokens = sign_in_device(extra: { app_session_id: victim.id })
    assert_not_equal victim.id, row_for(tokens).app_session_id
  end

  test "the device label is clamped" do
    tokens = sign_in_device(label: "x" * 5_000)
    assert_equal 100, row_for(tokens).device_label.length
  end

  test "token introspection is disabled" do
    tokens = sign_in_device
    post "/oauth/introspect", params: { token: tokens["access_token"], client_id: @client.uid }, headers: bearer(tokens)
    assert_not response.parsed_body["active"]
  end

  # --- refresh chain ----------------------------------------------------------

  test "app_session_id and the device label are copied forward on refresh" do
    t1 = sign_in_device(label: "Pixel 9")
    t2 = refresh(t1)
    use(t2)
    t3 = refresh(t2)

    rows = [ t1, t2, t3 ].map { |t| row_for(t) }
    assert_equal 1, rows.map(&:app_session_id).uniq.size
    assert_equal [ "Pixel 9" ] * 3, rows.map(&:device_label)
    assert_equal 1, AppSession.where(user: @user).count
  end

  test "access tokens live 15 minutes" do
    tokens = sign_in_device
    assert_equal 900, tokens["expires_in"]
    travel 14.minutes do
      use(tokens)
    end
    travel 16.minutes do
      get "/api/app/v1/session", headers: bearer(tokens)
      assert_response :unauthorized
      assert_equal "unauthorized", response.parsed_body.dig("error", "code")
      refresh(tokens) # the refresh token outlives the access token
    end
  end

  # --- the six spike cases (issue #94, round-1 amendment 2) ------------------

  test "case a: replaying a refresh token revoked by rotation revokes the whole family" do
    t1 = sign_in_device
    t2 = refresh(t1)
    use(t2)
    assert row_for(t1).revoked?, "Doorkeeper's deferred revocation retired t1 on t2's first use"

    refresh_raw(t1)
    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body["error"]

    session = AppSession.last
    assert_equal "reuse_detected", session.revocation_reason
    assert_empty live_tokens(session)
    get "/api/app/v1/session", headers: bearer(t2)
    assert_response :unauthorized
    refresh_raw(t2)
    assert_response :bad_request
  end

  test "case b: the same refresh token presented twice leaves one live child" do
    t1 = sign_in_device
    t2 = refresh(t1)
    t3 = refresh(t1) # t2 never used, so t1 is still inside its grace window
    session = AppSession.last

    assert row_for(t2).revoked?, "the earlier child is superseded"
    assert_equal [ row_for(t1), row_for(t3) ].map(&:id).sort, live_tokens(session).pluck(:id).sort
    get "/api/app/v1/session", headers: bearer(t2)
    assert_response :unauthorized

    use(t3)
    assert_equal [ row_for(t3).id ], live_tokens(session).pluck(:id)

    # A client that kept the superseded child is indistinguishable from a thief.
    refresh_raw(t2)
    assert_equal "invalid_grant", response.parsed_body["error"]
    assert_equal "reuse_detected", session.reload.revocation_reason
  end

  test "case c: a lost refresh response can be retried with the old token" do
    t1 = sign_in_device
    _lost = refresh(t1)
    t3 = refresh(t1)
    use(t3)
    t4 = refresh(t3)
    use(t4)
    session = AppSession.last
    assert_nil session.revoked_at
    assert_equal [ row_for(t4).id ], live_tokens(session).pluck(:id)
  end

  test "case d: siblings minted during deferred revocation are superseded" do
    t1 = sign_in_device
    t2 = refresh(t1)
    t3 = refresh(t1)
    t4 = refresh(t1)
    assert [ t2, t3 ].all? { |t| row_for(t).revoked? }
    assert_not row_for(t4).revoked?

    # Refreshing from the newest child before using it retires the grandparent
    # too, even though Doorkeeper would only revoke it on t4's first use.
    t5 = refresh(t4)
    assert row_for(t1).revoked?
    assert_equal [ row_for(t4).id, row_for(t5).id ].sort, live_tokens(AppSession.last).pluck(:id).sort
    use(t5)
    assert_equal [ row_for(t5).id ], live_tokens(AppSession.last).pluck(:id)
  end

  test "case e: a refresh after the device session is revoked cannot mint a live child" do
    t1 = sign_in_device
    session = AppSession.last
    session.revoke!(:user_revoked)
    # Even if a token row escaped the revocation sweep, the session check under the lock refuses it.
    Doorkeeper::AccessToken.where(app_session_id: session.id).update_all(revoked_at: nil)

    assert_no_difference -> { Doorkeeper::AccessToken.count } do
      refresh_raw(t1)
    end
    assert_equal "invalid_grant", response.parsed_body["error"]
    assert_equal "user_revoked", session.reload.revocation_reason
  end

  test "case f: replaying a token after logout is an invalid grant, not theft" do
    t1 = sign_in_device
    t2 = refresh(t1)
    delete "/api/app/v1/session", headers: bearer(t2)
    assert_response :no_content

    refresh_raw(t2)
    assert_equal "invalid_grant", response.parsed_body["error"]
    refresh_raw(t1)
    assert_equal "invalid_grant", response.parsed_body["error"]
    session = AppSession.last
    assert_equal "logout", session.revocation_reason
    assert_empty live_tokens(session)
  end

  test "RFC 7009 revocation signs the whole device out, and a replay stays a logout" do
    t1 = sign_in_device
    t2 = refresh(t1)
    post "/oauth/revoke", params: { token: t2["refresh_token"], token_type_hint: "refresh_token", client_id: @client.uid }
    assert_response :success
    get "/api/app/v1/session", headers: bearer(t2)
    assert_response :unauthorized

    refresh_raw(t1)
    assert_equal "invalid_grant", response.parsed_body["error"]
    assert_equal "logout", AppSession.last.revocation_reason
  end

  test "revocation needs the token's own client" do
    tokens = sign_in_device
    post "/oauth/revoke", params: { token: tokens["refresh_token"] }
    assert_response :forbidden
    assert_nil AppSession.last.revoked_at
  end

  # --- /api/app/v1/session ---------------------------------------------------

  test "session show needs a bearer token" do
    get "/api/app/v1/session"
    assert_response :unauthorized
    assert_equal "unauthorized", response.parsed_body.dig("error", "code")
  end

  test "session destroy signs out only this device" do
    phone = sign_in_device(label: "Pixel 9")
    tablet = sign_in_device(label: "Tab")
    delete "/api/app/v1/session", headers: bearer(phone)
    assert_response :no_content

    get "/api/app/v1/session", headers: bearer(phone)
    assert_response :unauthorized
    use(tablet)
    assert_equal 2, AppSession.where(user: @user).count
    assert_equal 1, AppSession.where(user: @user).live.count
  end

  test "the bearer is refused as soon as its device session is revoked" do
    tokens = sign_in_device
    use(tokens)
    AppSession.last.revoke!(:user_revoked)
    get "/api/app/v1/session", headers: bearer(tokens)
    assert_response :unauthorized
  end

  test "the bearer is refused if its session is revoked even when the token row escaped the sweep" do
    tokens = sign_in_device
    session = AppSession.last
    session.update_columns(revoked_at: Time.current, revocation_reason: "user_revoked")
    assert_not row_for(tokens).revoked?
    get "/api/app/v1/session", headers: bearer(tokens)
    assert_response :unauthorized
  end

  private

  def assert_no_code_issued
    code = response.location && Rack::Utils.parse_query(URI(response.location).query.to_s)["code"]
    assert_nil code, "no authorization code may be issued"
  end

end
