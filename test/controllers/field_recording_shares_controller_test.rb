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
    assert_match %r{/shared/transcripts#sht_[A-Za-z0-9_-]{43}\z}, url
    share = @recording.shares.sole
    assert_in_delta 1.week.from_now, share.expires_at, 5.seconds
    assert_equal @user, share.created_by

    get account_field_recording_path(@account, @recording)
    listed = inertia_props["shares"]
    assert_equal [ share.to_param ], listed.map { |entry| entry["id"] }
    refute_includes response.body, url.split("#").last, "the page never shows the token again"
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
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_nil inertia_props["transcript"], "the page itself carries nothing: the token isn't sent with it"

    body = reveal(token_of(url))
    assert_response :success
    transcript = body["transcript"]
    assert_equal "Board call", transcript["title"]
    assert_equal @recording.transcript_text, transcript["text"]
    assert_equal %w[duration_ms expires_at lines recorded_at text title], transcript.keys.sort
    assert_equal @recording.transcript_display_lines.map(&:stringify_keys), transcript["lines"]
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal 1, @recording.shares.sole.view_count
  end

  # Mira's review of #484: a token in the path is logged whole by the request
  # logger, whatever filter_parameters says. In the fragment it never reaches
  # the server; posted back, it is a filtered parameter.
  test "a link's token never reaches the request log" do
    sign_in
    url = make_link
    token = token_of(url)
    reset!

    log = capture_log do
      get URI(url).path
      reveal(token)
    end
    assert_includes log, %(Started GET "/shared/transcripts")
    assert_includes log, %(Started POST "/shared/transcripts")
    assert_includes log, "[FILTERED]"
    refute_includes log, token
    refute_includes log, token.delete_prefix("sht_")
  end

  test "a supplied transcript is shown as written, with no speaker it wasn't given" do
    sign_in
    supplied = claimed_recording(account: @account, user: @user, title: "Planning", transcript_source: "supplied")
    supplied.store_supplied_transcript!([
      { "spk" => "speaker_0", "s" => nil, "t" => "Agenda:\n- one\n- two" },
      { "spk" => nil, "s" => 5000, "t" => "We agreed on the following: Ship tomorrow." }
    ])
    post account_field_recording_shares_path(@account, supplied), params: { expiry: "1h" }, as: :json
    url = response.parsed_body.dig("share", "url")
    reset!

    lines = reveal(token_of(url)).dig("transcript", "lines")
    assert_equal "Agenda:\n- one\n- two", lines[0]["text"]
    assert_nil lines[0]["clock"]
    assert lines[0]["speaker"].present?
    assert_equal({ "clock" => "00:05", "speaker" => nil, "text" => "We agreed on the following: Ship tomorrow." }, lines[1])
  end

  test "an expired, revoked or unknown link shows nothing" do
    sign_in
    url = make_link(expiry: "1h")

    travel 2.hours do
      body = reveal(token_of(url))
      assert_response :not_found
      assert_nil body["transcript"]
      assert body["expired"]
    end

    url = make_link(expiry: "never")
    share = @recording.shares.order(:id).last
    delete account_field_recording_share_path(@account, @recording, share)
    assert share.reload.revoked?
    body = reveal(token_of(url))
    assert_response :not_found
    assert_nil body["transcript"]
    refute body["expired"]

    body = reveal("sht_#{'x' * 43}")
    assert_response :not_found
    assert_nil body["transcript"]
    assert_equal 0, @recording.shares.sum(:view_count)
  end

  test "deleting the recording ends its links" do
    sign_in
    url = make_link(expiry: "never")
    @recording.discard!
    body = reveal(token_of(url))
    assert_response :not_found
    assert_nil body["transcript"]
  end

  private

  def token_of(url) = URI(url).fragment

  def reveal(token)
    post shared_transcripts_path, params: { token: }, as: :json
    response.parsed_body
  end

  def capture_log
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    loggers = [ Rails, ActionController::Base, ActiveRecord::Base ]
    previous = loggers.map(&:logger)
    loggers.each { |owner| owner.logger = logger }
    yield
    io.string
  ensure
    loggers.zip(previous).each { |owner, was| owner.logger = was }
  end

  def inertia_props
    JSON.parse(Nokogiri::HTML(response.body).at_css("[data-page]")&.[]("data-page") || response.body)["props"]
  end

end
