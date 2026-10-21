require "test_helper"
require "support/field_recording_helpers"

class FieldRecordingSharesControllerTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    Setting.instance.update!(allow_agents: true)
    @recording = ready_recording(account: @account, user: @user, title: "Board call")
  end

  def sign_in
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  def make_link(expiry: "1d")
    post account_field_recording_shares_path(@account, @recording), params: { expiry: }, as: :json
    response.parsed_body.dig("share", "url")
  end

  test "a member makes a link and gets its URL once" do
    sign_in
    url = make_link(expiry: "1w")

    assert_response :created
    assert_match %r{/shared/transcripts/sht_}, url
    share = @recording.shares.sole
    assert_in_delta 1.week.from_now, share.expires_at, 5.seconds
    assert_equal @user, share.created_by

    get account_field_recording_path(@account, @recording)
    listed = inertia_props["shares"]
    assert_equal [ share.to_param ], listed.map { |entry| entry["id"] }
    refute_includes response.body, url.split("/").last, "the page never shows the token again"
  end

  test "a bad expiry, or a recording not yet transcribed, is refused" do
    sign_in
    post account_field_recording_shares_path(@account, @recording), params: { expiry: "forever" }, as: :json
    assert_response :unprocessable_entity

    queued = queued_recording(account: @account, user: @user)
    post account_field_recording_shares_path(@account, queued), params: { expiry: "1d" }, as: :json
    assert_response :unprocessable_entity
    assert_equal 0, FieldRecordingShare.count
  end

  test "no link can be made for another account's recording, or without signing in" do
    other_account = accounts(:regular_user_account) # user_1 isn't a member
    other = ready_recording(account: other_account, user: users(:regular_user), title: "Theirs")
    post account_field_recording_shares_path(@account, @recording), params: { expiry: "1d" }, as: :json
    refute response.successful?, "signed out"

    sign_in
    post account_field_recording_shares_path(other_account, other), params: { expiry: "1d" }, as: :json
    refute response.successful?
    post account_field_recording_shares_path(@account, other), params: { expiry: "1d" }, as: :json
    assert_response :not_found
    assert_equal 0, FieldRecordingShare.count
  end

  test "anyone with the link reads the transcript, signed out, and nothing else of the account" do
    sign_in
    url = make_link
    reset!

    get URI(url).path
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    props = inertia_props
    assert_equal "Board call", props.dig("transcript", "title")
    assert_equal @recording.transcript_text, props.dig("transcript", "text")
    assert_equal %w[duration_ms expires_at recorded_at text title], props["transcript"].keys.sort
    refute props.key?("user")
    assert_equal 1, @recording.shares.sole.view_count
  end

  test "an expired, revoked or unknown link shows nothing" do
    sign_in
    url = make_link(expiry: "1h")
    path = URI(url).path

    travel 2.hours do
      get path
      assert_response :not_found
      assert_nil inertia_props["transcript"]
      assert inertia_props["expired"]
    end

    url = make_link(expiry: "never")
    share = @recording.shares.order(:id).last
    delete account_field_recording_share_path(@account, @recording, share)
    assert share.reload.revoked?
    get URI(url).path
    assert_response :not_found
    assert_nil inertia_props["transcript"]
    refute inertia_props["expired"]

    get "/shared/transcripts/sht_#{'x' * 43}"
    assert_response :not_found
    assert_nil inertia_props["transcript"]
  end

  test "deleting the recording ends its links" do
    sign_in
    url = make_link(expiry: "never")
    @recording.discard!
    get URI(url).path
    assert_response :not_found
    assert_nil inertia_props["transcript"]
  end

  private

  def inertia_props
    JSON.parse(Nokogiri::HTML(response.body).at_css("[data-page]")&.[]("data-page") || response.body)["props"]
  end

end
