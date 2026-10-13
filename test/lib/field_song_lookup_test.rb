require "test_helper"
require "webmock/minitest"

class FieldSongLookupTest < ActiveSupport::TestCase

  LRCLIB = %r{\Ahttps://lrclib\.net/api/search}

  setup do
    @lookup = FieldSongLookup.new
  end

  test "a YouTube link gives a title and artist from oEmbed, asked by video id, not by the pasted address" do
    stub = stub_request(:get, "https://www.youtube.com/oembed")
      .with(query: { url: "https://www.youtube.com/watch?v=y8AWFf7EAc4", format: "json" })
      .to_return(status: 200, body: { title: "Jeff Buckley - Hallelujah (Official Video)", author_name: "JeffBuckleyVEVO" }.to_json)

    found = @lookup.from_link("https://youtu.be/y8AWFf7EAc4?si=tracking")
    assert_requested stub
    assert_equal "Hallelujah", found[:title]
    assert_equal "Jeff Buckley", found[:artist]
    assert found[:found]
    assert_equal "youtube", found[:link]["provider"]
  end

  test "without a dash in the title, the channel stands in for the artist" do
    stub_request(:get, %r{\Ahttps://www\.youtube\.com/oembed})
      .to_return(status: 200, body: { title: "Hallelujah", author_name: "Jeff Buckley - Topic" }.to_json)

    found = @lookup.from_link("https://www.youtube.com/watch?v=y8AWFf7EAc4")
    assert_equal [ "Hallelujah", "Jeff Buckley" ], [ found[:title], found[:artist] ]
  end

  test "a link with no provider lookup is still a link: the person types the title" do
    found = @lookup.from_link("https://grouper.bandcamp.com/track/heavy-water")
    assert_equal "bandcamp", found[:link]["provider"]
    assert_not found[:found]
    assert_match(/type it in/, found[:message])
    assert_not_requested :any, /.*/
  end

  test "a video YouTube doesn't know is a message, not a failure" do
    stub_request(:get, %r{\Ahttps://www\.youtube\.com/oembed}).to_return(status: 404, body: "Not Found")
    found = @lookup.from_link("https://www.youtube.com/watch?v=aaaaaaaaaaa")
    assert_not found[:found]
    assert_match(/private or removed/, found[:message])
  end

  test "something that isn't a web address can't be looked up" do
    assert_raises(FieldSongLookup::Unusable) { @lookup.from_link("file:///etc/passwd") }
    assert_raises(FieldSongLookup::Unusable) { @lookup.lyrics(title: "  ") }
  end

  test "lyric candidates carry what LRCLIB matched, the closest in length first, words before none" do
    stub_request(:get, LRCLIB).with(query: { track_name: "Hallelujah", artist_name: "Jeff Buckley" })
      .to_return(status: 200, body: [
        { id: 1, trackName: "Hallelujah (Live)", artistName: "Jeff Buckley", albumName: "Live at Sin-é", duration: 480.0,
          instrumental: false, plainLyrics: "live words" },
        { id: 2, trackName: "Hallelujah", artistName: "Jeff Buckley", albumName: "Grace", duration: 413.0,
          instrumental: false, plainLyrics: "Now I've heard there was a secret chord\nThat David played" },
        { id: 3, trackName: "Hallelujah", artistName: "Jeff Buckley", albumName: "Grace", duration: 413.0,
          instrumental: false, plainLyrics: nil }
      ].to_json)

    candidates = @lookup.lyrics(title: "Hallelujah", artist: "Jeff Buckley", duration_ms: 412_000)
    assert_equal [ 2, 1, 3 ], candidates.map(&:id)
    assert_equal "Grace", candidates.first.album
    assert_equal 413, candidates.first.duration_s
    assert_equal "Now I've heard there was a secret chord\nThat David played", candidates.first.lyrics
  end

  test "no match is an empty list" do
    stub_request(:get, LRCLIB).to_return(status: 200, body: "[]")
    assert_equal [], @lookup.lyrics(title: "A song nobody wrote")
  end

  test "LRCLIB being down, slow, or answering nonsense is a failure the page can say" do
    stub_request(:get, LRCLIB).to_return(status: 503, body: "busy")
    assert_raises(FieldSongLookup::Failed) { @lookup.lyrics(title: "Hallelujah") }

    stub_request(:get, LRCLIB).to_timeout
    assert_raises(FieldSongLookup::Failed) { @lookup.lyrics(title: "Hallelujah") }

    stub_request(:get, LRCLIB).to_return(status: 200, body: "<html>")
    assert_raises(FieldSongLookup::Failed) { @lookup.lyrics(title: "Hallelujah") }
  end

  test "an answer larger than the cap is cut off rather than read" do
    small = FieldSongLookup.new(max_bytes: 100)
    stub_request(:get, LRCLIB).to_return(status: 200, body: [ { id: 1, plainLyrics: "la " * 200 } ].to_json)
    assert_raises(FieldSongLookup::Failed) { small.lyrics(title: "Hallelujah") }
  end

  test "YouTube titles lose the uploader's decorations" do
    assert_equal [ "Radiohead", "No Surprises" ], FieldSongLookup.split_title("Radiohead – No Surprises [Official Music Video] (HD)")
    assert_equal [ nil, "Clair de Lune" ], FieldSongLookup.split_title("Clair de Lune (Audio)")
  end

end
