require "test_helper"
require "webmock/minitest"

class FieldSongsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @resident = agents(:research_assistant)
    Setting.instance.update!(allow_agents: true)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  test "a person shares a song from a link without its words yet; it shows in Songs and in Needs you" do
    post account_field_songs_path(@account), params: { field_song: {
      title: "Hallelujah", artist: "Jeff Buckley", links: [ "https://youtu.be/y8AWFf7EAc4" ],
      note: "The version from the kitchen", shared_for: FieldSong.person_key(@resident)
    } }
    song = @account.field_songs.last
    assert_redirected_to account_field_path(@account, tab: "songs", item: "song-#{song.to_param}")
    assert_equal @user, song.added_by
    assert_equal @resident, song.shared_for
    assert_equal "missing", song.lyrics_state

    get account_field_path(@account, tab: "waiting")
    props = inertia_props
    assert_equal 1, props["counts"]["songs"]
    assert_equal 1, props["counts"]["waiting"]
    assert_equal [ "song-#{song.to_param}" ], props["items"].map { it["key"] }
    assert_includes props["song_recipients"].map { it["key"] }, FieldSong.person_key(@resident)

    patch account_field_song_path(@account, song), params: { field_song: { lyrics: "Now I've heard\nthere was a secret chord" } }
    assert_equal "present", song.reload.lyrics_state
    get account_field_path(@account, tab: "waiting")
    assert_equal 0, inertia_props["counts"]["waiting"]
  end

  test "the open song carries its words and links; the list leaves the words behind" do
    song = @account.field_songs.create!(title: "Hallelujah", links: [ "https://youtu.be/y8AWFf7EAc4" ],
      lyrics: "secret chord", added_by: @user)

    get account_field_path(@account, tab: "songs", item: "song-#{song.to_param}")
    props = inertia_props
    assert_equal "secret chord", props["current_item"]["lyrics"]
    assert_equal "YouTube", props["current_item"]["links"].first["label"]
    assert_nil props["items"].first["lyrics"]
  end

  test "a song with no way to hear it is refused with a reason" do
    post account_field_songs_path(@account), params: { field_song: { title: "Hallelujah", lyrics: "words" } }
    assert_redirected_to account_field_path(@account, tab: "songs")
    assert_equal 0, @account.field_songs.count
  end

  test "an mp3 dropped in fills the title and artist from its tags" do
    post account_field_songs_path(@account), params: { field_song: { audio: fixture_file_upload("field_song.mp3", "audio/mpeg") } }
    song = @account.field_songs.last
    assert_equal [ "Hallelujah", "Jeff Buckley" ], [ song.title, song.artist ]
    assert song.audio.attached?
  end

  test "lookup from the page suggests a title from a link, and says when it can't" do
    stub_request(:get, %r{\Ahttps://www\.youtube\.com/oembed})
      .to_return(status: 200, body: { title: "Jeff Buckley - Hallelujah (Official Video)", author_name: "x" }.to_json)
    get lookup_account_field_songs_path(@account), params: { url: "https://youtu.be/y8AWFf7EAc4" }
    assert_response :success
    assert_equal "Hallelujah", response.parsed_body.dig("suggestion", "title")

    stub_request(:get, %r{\Ahttps://lrclib\.net/api/search}).to_timeout
    get lookup_account_field_songs_path(@account), params: { title: "Hallelujah" }
    assert_response :bad_gateway
  end

  test "deleting discards" do
    song = @account.field_songs.create!(title: "Hallelujah", links: [ "https://youtu.be/y8AWFf7EAc4" ], added_by: @user)
    delete account_field_song_path(@account, song)
    assert song.reload.discarded?
  end

  private

  def inertia_props
    JSON.parse(Nokogiri::HTML(response.body).at_css("[data-page]")&.[]("data-page") || response.body)["props"]
  end

end
