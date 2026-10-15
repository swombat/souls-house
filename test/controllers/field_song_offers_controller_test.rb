require "test_helper"
require "webmock/minitest"

class FieldSongOffersControllerTest < ActionDispatch::IntegrationTest

  URL = "https://youtu.be/y8AWFf7EAc4"
  EQUIVALENT_URL = "https://www.youtube.com/watch?v=y8AWFf7EAc4&feature=shared"

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    Setting.instance.update!(allow_agents: true)
    sign_in(@user)
  end

  test "preview is local, no-store, and does not save a song" do
    assert_no_difference "FieldSong.count" do
      get offer_account_field_songs_path(@account), params: { url: URL }, as: :json
    end
    assert_response :success
    assert_equal({ "provider" => "youtube", "url" => URL, "embed_id" => "y8AWFf7EAc4" }, response.parsed_body["link"])
    assert_nil response.parsed_body["song"]
    assert_equal false, response.parsed_body["created"]
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_not_requested :any, /./
  end

  test "a flat POST saves only the link and supplied title and artist attributed to the session user" do
    assert_difference "FieldSong.count", 1 do
      post offer_account_field_songs_path(@account), params: {
        url: URL, title: "  Hallelujah  ", artist: "Jeff Buckley",
        lyrics: "Do not copy", note: "Do not copy", instrumental: true,
        shared_for: FieldSong.person_key(agents(:research_assistant)),
        added_by_id: users(:existing_user).id, added_by_type: "User",
        account_id: accounts(:team_account).to_param
      }, as: :json
    end
    assert_response :success
    song = @account.field_songs.last
    assert_equal [ "Hallelujah", "Jeff Buckley" ], [ song.title, song.artist ]
    assert_equal @user, song.added_by
    assert_nil song.lyrics
    assert_nil song.note
    assert_nil song.shared_for
    assert_not song.instrumental
    assert_equal "missing", song.lyrics_state
    assert_equal song.to_param, response.parsed_body.dig("song", "id")
    assert_equal true, response.parsed_body["created"]
    assert_equal "youtube", response.parsed_body.dig("link", "provider")
    assert_not_requested :any, /./
  end

  test "equivalent links fetch the kept song without overwriting any metadata or attribution" do
    original = @account.field_songs.create!(title: "Original", artist: "Original artist", album: "Original album",
      links: [ URL ], lyrics: "Kept words", note: "Kept note", added_by: agents(:research_assistant),
      shared_for: @user, year: 1994)
    before = original.attributes

    get offer_account_field_songs_path(@account), params: { url: EQUIVALENT_URL }, as: :json
    assert_response :success
    assert_equal original.to_param, response.parsed_body.dig("song", "id")
    assert_equal false, response.parsed_body["created"]
    assert_equal "Kept words", response.parsed_body.dig("song", "lyrics")
    2.times do
      assert_no_difference "FieldSong.count" do
        post offer_account_field_songs_path(@account), params: {
          url: EQUIVALENT_URL, title: "Replacement", artist: "Replacement artist"
        }, as: :json
      end
      assert_response :success
      assert_equal original.to_param, response.parsed_body.dig("song", "id")
      assert_equal false, response.parsed_body["created"]
    end
    assert_equal before, original.reload.attributes
  end

  test "discarded and other-account songs do not match" do
    discarded = @account.field_songs.create!(title: "Discarded", links: [ URL ])
    discarded.discard!
    accounts(:team_account).field_songs.create!(title: "Elsewhere", links: [ URL ])

    get offer_account_field_songs_path(@account), params: { url: URL }, as: :json
    assert_response :success
    assert_nil response.parsed_body["song"]
    assert_difference "@account.field_songs.kept.count", 1 do
      post offer_account_field_songs_path(@account), params: { url: URL, title: "New" }, as: :json
    end
    assert_response :success
    assert_not_equal discarded.to_param, response.parsed_body.dig("song", "id")
    assert_equal true, response.parsed_body["created"]
    assert discarded.reload.discarded?
  end

  test "a newly offered song can be recoverably discarded with a JSON success response" do
    post offer_account_field_songs_path(@account), params: { url: URL, title: "Accidental addition" }, as: :json
    assert_response :success
    song = @account.field_songs.find(response.parsed_body.dig("song", "id"))
    assert_equal true, response.parsed_body["created"]

    assert_no_difference "FieldSong.count" do
      delete account_field_song_path(@account, song), as: :json
    end
    assert_response :no_content
    assert song.reload.discarded?
    get offer_account_field_songs_path(@account), params: { url: URL }, as: :json
    assert_nil response.parsed_body["song"]
    assert_equal false, response.parsed_body["created"]
  end

  test "JSON discard retains account, authentication and feature boundaries" do
    other = accounts(:team_account).field_songs.create!(title: "Elsewhere", links: [ URL ])
    delete account_field_song_path(@account, other), as: :json
    assert_response :not_found
    assert other.reload.kept?

    song = @account.field_songs.create!(title: "Kept here", links: [ URL ])
    Setting.instance.update!(allow_agents: false)
    delete account_field_song_path(@account, song), as: :json
    assert_redirected_to root_path
    assert song.reload.kept?
    Setting.instance.update!(allow_agents: true)

    delete logout_path
    delete account_field_song_path(@account, song), as: :json
    assert_redirected_to login_path
    assert song.reload.kept?
  end

  test "title is required and title and artist are bounded to 200 characters" do
    [ { title: "" }, { title: " " }, { title: "t" * 201 }, { title: "Title", artist: "a" * 201 } ].each do |attributes|
      assert_no_difference "FieldSong.count" do
        post offer_account_field_songs_path(@account), params: { url: URL }.merge(attributes), as: :json
      end
      assert_response :unprocessable_entity
      assert response.parsed_body["error"].present?
    end
    post offer_account_field_songs_path(@account), params: { url: URL, title: "t" * 200, artist: "a" * 200 }, as: :json
    assert_response :success
  end

  test "unsupported and unsafe links are unavailable on both preview and save" do
    [
      "", "javascript:alert(1)", "file:///etc/passwd", "https://example.com/song",
      "http://localhost/song", "http://127.0.0.1/song", "http://10.0.0.1/song",
      "http://169.254.169.254/song", "http://[::1]/song",
      "https://youtube.com.evil.example/watch?v=y8AWFf7EAc4",
      "https://youtube.com@127.0.0.1/watch?v=y8AWFf7EAc4",
      "https://user:password@youtube.com/watch?v=y8AWFf7EAc4",
      "https://youtube.com:8443/watch?v=y8AWFf7EAc4",
      "https://youtu.be/y8AW\nFf7EAc4", "https://youtu.be/#{'x' * 501}"
    ].each do |url|
      assert_no_difference "FieldSong.count" do
        get offer_account_field_songs_path(@account), params: { url: url }, as: :json
        assert_response :unprocessable_entity
        assert_includes response.headers["Cache-Control"], "no-store"
        post offer_account_field_songs_path(@account), params: { url: url, title: "Unsafe" }, as: :json
        assert_response :unprocessable_entity
      end
    end
    assert_not_requested :any, /./
  end

  test "offer requires a session and account access for reads and writes" do
    outside = Account.create!(name: "Outside offer account", account_type: :team)
    [ :get, :post ].each do |verb|
      public_send(verb, offer_account_field_songs_path(outside), params: { url: URL, title: "No access" }, as: :json)
      assert_response :not_found
    end
    assert_equal 0, outside.field_songs.count

    delete logout_path
    [ :get, :post ].each do |verb|
      public_send(verb, offer_account_field_songs_path(@account), params: { url: URL, title: "No session" }, as: :json)
      assert_redirected_to login_path
    end
    assert_equal 0, @account.field_songs.count
  end

  test "an unconfirmed membership does not grant offer access" do
    outside = Account.create!(name: "Pending offer account", account_type: :team)
    outside.memberships.create!(user: @user, role: :member)
    [ :get, :post ].each do |verb|
      public_send(verb, offer_account_field_songs_path(outside), params: { url: URL, title: "Pending" }, as: :json)
      assert_response :not_found
    end
    assert_equal 0, outside.field_songs.count
  end

  test "a confirmed ordinary member can save and is the attributed person" do
    delete logout_path
    member = users(:existing_user)
    account = accounts(:team_account)
    sign_in(member)
    assert_equal "member", member.memberships.find_by!(account: account).role

    post offer_account_field_songs_path(account), params: { url: URL, title: "Member's song" }, as: :json
    assert_response :success
    song = account.field_songs.last
    assert_equal member, song.added_by
    get offer_account_field_songs_path(account), params: { url: EQUIVALENT_URL }, as: :json
    assert_response :success
    assert_equal song.to_param, response.parsed_body.dig("song", "id")
  end

  test "the agents feature gate denies both preview and save without writing" do
    Setting.instance.update!(allow_agents: false)
    assert_no_difference "FieldSong.count" do
      [ :get, :post ].each do |verb|
        public_send(verb, offer_account_field_songs_path(@account), params: { url: URL, title: "Disabled" }, as: :json)
        assert_redirected_to root_path
      end
    end
  end

end
