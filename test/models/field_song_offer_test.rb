require "test_helper"

class FieldSongOfferTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
  end

  test "supported providers without embeds remain usable as outside links" do
    {
      "https://music.apple.com/us/album/example/123456" => "apple_music",
      "https://artist.bandcamp.com/track/example" => "bandcamp",
      "https://soundcloud.com/artist/example" => "soundcloud",
      "https://open.spotify.com/something-without-an-embed" => "spotify",
      "https://www.youtube.com/playlist?list=example" => "youtube"
    }.each do |url, provider|
      offer = FieldSong::Offer.new(account: @account, url: url)
      assert_equal provider, offer.link["provider"]
      assert_nil offer.link["embed_id"]
      song = offer.save!(title: "External song", artist: nil, by: @user)
      assert_equal url, song.links.first["url"]
      assert_equal song, FieldSong::Offer.new(account: @account, url: url).existing_song
    end
  end

  test "fallback deduplicates by normalized URL, not just provider" do
    first = FieldSong::Offer.new(account: @account, url: "http://soundcloud.com/artist/first")
      .save!(title: "First", artist: nil, by: @user)
    again = FieldSong::Offer.new(account: @account, url: " https://soundcloud.com/artist/first ")
      .save!(title: "Ignored", artist: nil, by: @user)
    other = FieldSong::Offer.new(account: @account, url: "https://soundcloud.com/artist/second")
      .save!(title: "Second", artist: nil, by: @user)
    assert_equal first.id, again.id
    assert_not_equal first.id, other.id
  end

  test "all recognized YouTube forms use provider and embed identity including secondary saved links" do
    song = @account.field_songs.create!(title: "Song", links: [
      "https://soundcloud.com/artist/example", "https://youtu.be/y8AWFf7EAc4"
    ])
    [
      "https://www.youtube.com/watch?v=y8AWFf7EAc4&si=tracking",
      "https://music.youtube.com/watch?v=y8AWFf7EAc4",
      "https://youtube.com/shorts/y8AWFf7EAc4",
      "https://www.youtube-nocookie.com/embed/y8AWFf7EAc4",
      "https://youtube.com/live/y8AWFf7EAc4"
    ].each do |url|
      assert_equal song.id, FieldSong::Offer.new(account: @account, url: url).existing_song.id
    end
  end

  test "spotify equivalent links deduplicate but a different resource type does not" do
    track = "4uLU6hMCjMI75M1A2tKUQC"
    song = FieldSong::Offer.new(account: @account, url: "https://open.spotify.com/track/#{track}?si=one")
      .save!(title: "Track", artist: nil, by: @user)
    assert_equal song.id, FieldSong::Offer.new(account: @account,
      url: "https://open.spotify.com/intl-es/track/#{track}?si=two").existing_song.id
    assert_nil FieldSong::Offer.new(account: @account, url: "https://open.spotify.com/album/#{track}").existing_song
  end

  test "offer safety does not change general Field link support" do
    url = "https://example.com/music"
    assert_equal "other", FieldSong::Links.normalise(url)["provider"]
    song = @account.field_songs.create!(title: "Existing web song", links: [ url ])
    assert song.persisted?
    assert_raises(FieldSong::Offer::InvalidLink) { FieldSong::Offer.new(account: @account, url: url) }
  end

  test "offered URLs are read the way the page reads offers, whole" do
    content = <<~TEXT
      Two songs for you:

      [[song:https://soundcloud.com/artist/song-remix|Song (remix)|Artist]]

      [[song:https://example.com/a\\|b|Escaped pipe]]
      [[song:AbC123]]
      [[song:https://youtu.be/one|a|b|too many fields]]
      [[song:https://youtu.be/two|bad \\x escape]]
      Inline [[song:https://youtu.be/three]] is not an offer
    TEXT
    assert_equal [ "https://soundcloud.com/artist/song-remix", "https://example.com/a|b" ],
      FieldSong::Offer.offered_urls(content)
    assert_not_includes FieldSong::Offer.offered_urls(content), "https://soundcloud.com/artist/song"
  end

end
