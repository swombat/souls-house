require "test_helper"
require "webmock/minitest"
require "support/api_human_key_helpers"

class Api::V1::Field::SongsControllerTest < ActionDispatch::IntegrationTest

  include ApiHumanKeyHelpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @resident = agents(:research_assistant)
    @account = @resident.account
    @user = users(:user_1)
    @headers = resident_headers(@user, @resident)
  end

  test "a resident adds a song from a link with its words; it is attributed to the resident, not the person who shared it" do
    post api_v1_field_songs_path, headers: @headers, as: :json, params: {
      title: "Hallelujah", artist: "Jeff Buckley", links: [ "https://youtu.be/y8AWFf7EAc4" ],
      lyrics: "Now I've heard there was a secret chord\nThat David played",
      note: "Daniel shared this in our chat (OYzLwj) on a slow evening.", shared_for: "Research Assistant", tags: [ "ours" ]
    }
    assert_response :created
    song = response.parsed_body["song"]
    assert_equal({ "kind" => "resident", "name" => @resident.name }, song["added_by"])
    assert_equal "present", song["lyrics_state"]
    assert_equal "Now I've heard there was a secret chord\nThat David played", song["lyrics"]
    assert_equal "resident", song.dig("shared_for", "kind")
    assert_equal [ "ours" ], song["tags"]
    assert_equal "y8AWFf7EAc4", song["links"].first["embed_id"]
    assert_nil song["audio"]
  end

  test "a song saved before its words says they are missing, waits, and takes them later" do
    post api_v1_field_songs_path, headers: @headers, as: :json,
      params: { title: "Gymnopédie No. 1", links: "https://open.spotify.com/track/5NGtFXVpXSvwunEIGeviY3" }
    assert_response :created
    id = response.parsed_body.dig("song", "id")
    assert_equal "missing", response.parsed_body.dig("song", "lyrics_state")
    assert_nil response.parsed_body.dig("song", "lyrics")

    get api_v1_field_songs_path, params: { lyrics: "missing" }, headers: @headers
    assert_equal [ id ], response.parsed_body["songs"].map { it["id"] }

    patch api_v1_field_song_path(id), headers: @headers, as: :json, params: { lyrics: "la la\nla" }
    assert_response :success
    assert_equal "present", response.parsed_body.dig("song", "lyrics_state")
    assert_equal "Gymnopédie No. 1", response.parsed_body.dig("song", "title")
    get api_v1_field_songs_path, params: { lyrics: "missing" }, headers: @headers
    assert_empty response.parsed_body["songs"]
  end

  test "instrumental is said on purpose and doesn't wait" do
    post api_v1_field_songs_path, headers: @headers, as: :json,
      params: { title: "Spiegel im Spiegel", artist: "Arvo Pärt", links: [ "https://youtu.be/TJ6Mzvh3XCc" ], instrumental: true }
    assert_response :created
    assert_equal "instrumental", response.parsed_body.dig("song", "lyrics_state")
    get api_v1_field_songs_path, params: { lyrics: "missing" }, headers: @headers
    assert_empty response.parsed_body["songs"]
  end

  test "a song with no way to hear it is refused" do
    post api_v1_field_songs_path, headers: @headers, as: :json, params: { title: "Hallelujah", lyrics: "words" }
    assert_response :unprocessable_entity
    assert_match(/link .* or an audio file/, response.parsed_body["error"])
  end

  test "an audio file comes in by multipart and goes out to whoever can listen" do
    post api_v1_field_songs_path, headers: @headers,
      params: { audio: fixture_file_upload("field_song.mp3", "audio/mpeg"), note: "Recorded at home" }
    assert_response :created
    song = response.parsed_body["song"]
    assert_equal "Hallelujah", song["title"]
    assert_equal "Jeff Buckley", song["artist"]
    assert song.dig("audio", "audio_path")

    get song.dig("audio", "audio_path"), headers: @headers
    assert_response :redirect
  end

  test "songs are found by their words with kind=song, and tagged" do
    song = @account.field_songs.create!(title: "Hallelujah", links: [ "https://youtu.be/y8AWFf7EAc4" ],
      lyrics: "the baffled king composing", added_by: @user)

    get api_v1_field_search_path, params: { query: "baffled", kind: "song" }, headers: @headers
    assert_equal [ [ "song", song.to_param ] ], response.parsed_body["results"].map { [ it["kind"], it["id"] ] }

    patch api_v1_field_song_tags_path(song), params: { add: [ "kitchen" ] }, headers: @headers, as: :json
    assert_response :success
    get api_v1_field_songs_path, params: { tag: "kitchen" }, headers: @headers
    assert_equal [ song.to_param ], response.parsed_body["songs"].map { it["id"] }
  end

  test "a resident deletes only the songs it added" do
    theirs = @account.field_songs.create!(title: "Theirs", links: [ "https://youtu.be/y8AWFf7EAc4" ], added_by: @user)
    mine = @account.field_songs.create!(title: "Mine", links: [ "https://youtu.be/y8AWFf7EAc4" ], added_by: @resident)

    delete api_v1_field_song_path(theirs), headers: @headers
    assert_response :forbidden
    delete api_v1_field_song_path(mine), headers: @headers
    assert_response :no_content
    assert mine.reload.discarded?
  end

  test "lookup suggests, never saves: a song's typed words are untouched by any lookup" do
    song = @account.field_songs.create!(title: "Hallelujah", artist: "Jeff Buckley", links: [ "https://youtu.be/y8AWFf7EAc4" ],
      lyrics: "my own transcription\nline two", added_by: @user)
    stub_request(:get, %r{\Ahttps://lrclib\.net/api/search})
      .to_return(status: 200, body: [ { id: 7, trackName: "Hallelujah", artistName: "Jeff Buckley", albumName: "Grace",
                                        duration: 413, instrumental: false, plainLyrics: "LRCLIB's words" } ].to_json)

    assert_no_changes -> { FieldSong.count } do
      get lookup_api_v1_field_songs_path, params: { title: "Hallelujah", artist: "Jeff Buckley" }, headers: @headers
    end
    assert_response :success
    candidate = response.parsed_body["candidates"].first
    assert_equal [ "Hallelujah", "Jeff Buckley", "Grace", 413 ], candidate.values_at("title", "artist", "album", "duration_s")
    assert_equal "my own transcription\nline two", song.reload.lyrics
  end

  test "a failed lookup says so, and the song can still be saved by hand" do
    stub_request(:get, %r{\Ahttps://lrclib\.net/api/search}).to_return(status: 500)
    get lookup_api_v1_field_songs_path, params: { title: "Hallelujah" }, headers: @headers
    assert_response :bad_gateway
    assert_match(/lrclib\.net answered 500/, response.parsed_body["error"])

    post api_v1_field_songs_path, headers: @headers, as: :json,
      params: { title: "Hallelujah", links: [ "https://youtu.be/y8AWFf7EAc4" ], lyrics: "typed by hand" }
    assert_response :created
    assert_equal "typed by hand", response.parsed_body.dig("song", "lyrics")
  end

  test "a lookup without a title or with a non-web address is refused, not sent anywhere" do
    get lookup_api_v1_field_songs_path, params: { url: "ftp://example.com/x" }, headers: @headers
    assert_response :unprocessable_entity
    get lookup_api_v1_field_songs_path, headers: @headers
    assert_response :unprocessable_entity
    assert_not_requested :any, /.*/
  end

  test "shared_for must be someone in the account" do
    post api_v1_field_songs_path, headers: @headers, as: :json,
      params: { title: "Hallelujah", links: [ "https://youtu.be/y8AWFf7EAc4" ], shared_for: "Someone Else Entirely" }
    assert_response :unprocessable_entity
    assert_match(/Nobody in this account/, response.parsed_body["error"])
  end

end
