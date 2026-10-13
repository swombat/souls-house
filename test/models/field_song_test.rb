require "test_helper"

class FieldSongTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @resident = agents(:research_assistant)
  end

  def song(**attributes)
    @account.field_songs.new({ title: "Hallelujah", artist: "Jeff Buckley", added_by: @user }.merge(attributes))
  end

  test "a song has to be hearable: a link or an audio file" do
    unheard = song
    assert_not unheard.valid?
    assert_match(/link .* or an audio file/, unheard.errors.full_messages.to_sentence)

    assert song(links: [ "https://youtu.be/y8AWFf7EAc4" ]).valid?

    with_file = song(title: "")
    with_file.audio.attach(Rack::Test::UploadedFile.new(file_fixture("field_song.mp3"), "audio/mpeg"))
    assert with_file.valid?
  end

  test "links are normalised to a provider and the id a player needs, and the address is kept" do
    record = song(links: [
      "https://www.youtube.com/watch?v=y8AWFf7EAc4&t=10s",
      "https://open.spotify.com/intl-es/track/3pRaLNL3b8x5uBOcsgvdqM?si=abc",
      "https://grouper.bandcamp.com/album/ruins",
      "https://www.youtube.com/watch?v=y8AWFf7EAc4&t=10s"
    ])
    record.save!

    assert_equal [ "youtube", "spotify", "bandcamp" ], record.links.map { it["provider"] }
    assert_equal "y8AWFf7EAc4", record.links[0]["embed_id"]
    assert_equal "track/3pRaLNL3b8x5uBOcsgvdqM", record.links[1]["embed_id"]
    assert_nil record.links[2]["embed_id"]
    assert_equal "https://open.spotify.com/intl-es/track/3pRaLNL3b8x5uBOcsgvdqM?si=abc", record.links[1]["url"]
  end

  test "something that isn't a web address is refused by name, and more than four links are refused" do
    record = song(links: [ "javascript:alert(1)", "https://youtu.be/y8AWFf7EAc4" ])
    assert_not record.valid?
    assert_match(/javascript:alert\(1\) isn't a web address/, record.errors.full_messages.to_sentence)

    many = song(links: (1..5).map { "https://example.com/#{it}" })
    assert_not many.valid?
    assert_match(/at most 4/, many.errors.full_messages.to_sentence)
  end

  test "lyrics keep their line breaks; without them the song waits, unless it is instrumental" do
    words = "Now I've heard there was a secret chord\r\nThat David played\r\n\r\nAnd it pleased the Lord"
    with_words = song(links: [ "https://youtu.be/y8AWFf7EAc4" ], lyrics: "  #{words}\n\n")
    with_words.save!
    assert_equal "Now I've heard there was a secret chord\nThat David played\n\nAnd it pleased the Lord", with_words.lyrics
    assert_equal "present", with_words.lyrics_state

    waiting = song(title: "Gymnopédie No. 1", links: [ "https://youtu.be/S-Xm7s9eGxU" ], lyrics: "   \n ")
    waiting.save!
    assert_equal "missing", waiting.lyrics_state
    assert_nil waiting.lyrics

    instrumental = song(title: "Spiegel im Spiegel", links: [ "https://youtu.be/TJ6Mzvh3XCc" ], instrumental: true)
    instrumental.save!
    assert_equal "instrumental", instrumental.lyrics_state

    assert_equal [ waiting ], @account.field_songs.lyrics_missing.to_a
  end

  test "a song with words can't also be called instrumental" do
    record = song(links: [ "https://youtu.be/y8AWFf7EAc4" ], lyrics: "words", instrumental: true)
    assert_not record.valid?
    assert_includes record.errors[:instrumental], "can't be set on a song with lyrics"
  end

  test "a song can be for someone in the account, and only someone in it" do
    record = song(links: [ "https://youtu.be/y8AWFf7EAc4" ], shared_for: @resident)
    assert record.valid?

    stranger = Agent.where.not(account_id: @account.id).first
    if stranger
      record.shared_for = stranger
      assert_not record.valid?
      assert_includes record.errors[:shared_for], "must be someone in this account"
    end
  end

  test "recipients are found by key or exact name" do
    assert_equal @resident, FieldSong.find_recipient(@account, FieldSong.person_key(@resident))
    assert_equal @resident, FieldSong.find_recipient(@account, @resident.name.upcase)
    assert_nil FieldSong.find_recipient(@account, " ")
    assert_raises(FieldSong::UnknownRecipient) { FieldSong.find_recipient(@account, "Nobody Of That Name") }
  end

  test "an audio file's own tags fill only what was left blank, and its length is read" do
    record = @account.field_songs.new(title: "", artist: "Someone I typed", added_by: @user)
    record.audio.attach(Rack::Test::UploadedFile.new(file_fixture("field_song.mp3"), "audio/mpeg"))
    record.save!

    assert_equal "Hallelujah", record.title
    assert_equal "Someone I typed", record.artist
    assert_equal "Grace", record.album
    assert_equal 1994, record.year
    assert_in_delta 1000, record.duration_ms, 100
  end

  test "a file that isn't audio is refused" do
    record = song(links: [ "https://youtu.be/y8AWFf7EAc4" ])
    record.audio.attach(Rack::Test::UploadedFile.new(file_fixture("test.txt"), "text/plain"))
    assert_not record.valid?
    assert_match(/must be an audio file/, record.errors.full_messages.to_sentence)
  end

  test "lyrics are searchable, and a song is found by its title, note and words" do
    record = song(links: [ "https://youtu.be/y8AWFf7EAc4" ], lyrics: "the baffled king composing hallelujah",
      note: "For the kitchen at 2am")
    record.save!

    %w[baffled kitchen buckley].each do |word|
      found = FieldSearch.new(account: @account, query: word, kinds: [ "song" ]).call.results
      assert_equal [ record ], found.map(&:record), "expected #{word} to find the song"
    end
    excerpt = FieldSearch.new(account: @account, query: "baffled", kinds: [ "song" ]).call.results.first.excerpts.first
    assert_includes excerpt[:text], "baffled king"
  end

  test "a discarded song leaves the Field's lists, search and tags" do
    record = song(links: [ "https://youtu.be/y8AWFf7EAc4" ], lyrics: "secret chord")
    record.save!
    record.change_tags!(by: @user, add: [ "ours" ])
    record.discard!

    assert_empty FieldSearch.new(account: @account, query: "secret", kinds: [ "song" ]).call.results
    assert_not FieldTagging.visible_in(@account).exists?(taggable: record)
  end

end
