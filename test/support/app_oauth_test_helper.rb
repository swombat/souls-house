# Drives the native-app sign-in (issue #94) through the real Doorkeeper
# endpoints: browser authorize with PKCE, code exchange, refresh, API use.
module AppOauthTestHelper

  CALLBACK = "https://souls.house/app/oauth/callback".freeze

  private

  def create_app_client
    Doorkeeper::Application.create!(
      name: "Souls House for Android", uid: "souls-house-android",
      redirect_uri: CALLBACK, scopes: "chat", confidential: false
    )
  end

  def challenge_for(verifier)
    Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
  end

  def authorize_params(challenge, label: "Pixel 9")
    { client_id: @client.uid, redirect_uri: CALLBACK, response_type: "code", scope: "chat",
      code_challenge: challenge, code_challenge_method: "S256", device_label: label, state: "s1" }
  end

  def authorize_code(challenge, label: "Pixel 9", extra: {})
    sign_in @user
    get "/oauth/authorize", params: authorize_params(challenge, label: label).merge(extra)
    code_from_callback
  end

  def code_from_callback
    assert_response :redirect
    location = response.location
    assert location.start_with?("#{CALLBACK}?"), "expected a redirect to the callback, got #{location}"
    Rack::Utils.parse_query(URI(location).query).fetch("code")
  end

  def exchange_code(code, verifier)
    post "/oauth/token", params: { grant_type: "authorization_code", code: code, client_id: @client.uid,
                                   redirect_uri: CALLBACK, code_verifier: verifier }
  end

  def sign_in_device(label: "Pixel 9", extra: {})
    verifier = SecureRandom.urlsafe_base64(48)
    exchange_code(authorize_code(challenge_for(verifier), label: label, extra: extra), verifier)
    assert_response :success
    response.parsed_body
  end

  def refresh_raw(tokens)
    post "/oauth/token", params: { grant_type: "refresh_token", refresh_token: tokens["refresh_token"], client_id: @client.uid }
  end

  def refresh(tokens)
    refresh_raw(tokens)
    assert_response :success
    response.parsed_body
  end

  def use(tokens)
    get "/api/app/v1/session", headers: bearer(tokens)
    assert_response :success
  end

  def bearer(tokens)
    { "Authorization" => "Bearer #{tokens['access_token']}" }
  end

  def row_for(tokens)
    Doorkeeper::AccessToken.by_refresh_token(tokens["refresh_token"])
  end

  def live_tokens(app_session)
    Doorkeeper::AccessToken.where(app_session_id: app_session.id, revoked_at: nil)
  end

end
