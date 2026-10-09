require "test_helper"
require "support/field_recording_helpers"

class FieldSearchTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @user = users(:user_1)
    @account = agents(:research_assistant).account
    @recording = ready_recording(account: @account, user: @user, title: "Board call")
    @recording.update_columns(transcript_text: "[00:00] Daniel: we talked about the GrantTree valuation\n[00:09] Bob: " \
      "and the sale timeline, which slipped again.")
    @file = @account.field_files.create!(file: upload, title: "Shopping list", uploaded_by: @user, note: "for the valuation dinner")
    @note = @account.whiteboards.create!(name: "Music plans", content: "Practice the Bach partita every morning.")
  end

  test "every word must appear, anywhere in the body, case-insensitively" do
    results = search(query: "grantTREE timeline").results
    assert_equal [ [ "recording", @recording.id ] ], results.map { |r| [ r.kind, r.record.id ] }

    assert_empty search(query: "granttree partita").results
  end

  test "a quoted phrase needs its words together, and a minus excludes" do
    assert_equal 1, search(query: "\"sale timeline\"").results.size
    assert_empty search(query: "\"timeline sale\"").results
    kinds = search(query: "valuation").results.map(&:kind).sort
    assert_equal %w[file recording], kinds
    assert_equal %w[file], search(query: "valuation -granttree").results.map(&:kind)
  end

  test "notes and files are searched, title and body" do
    assert_equal [ @note.id ], search(query: "bach").results.map { |r| r.record.id }
    assert_equal [ @note.id ], search(query: "music").results.map { |r| r.record.id }
    assert_equal [ @file.id ], search(query: "shopping").results.map { |r| r.record.id }
  end

  test "excerpts mark the matched words by offset in plain text" do
    result = search(query: "valuation", kinds: [ "recording" ]).results.first
    excerpt = result.excerpts.first
    assert_not_includes excerpt[:text], "\u0002"
    offset, length = excerpt[:matches].first
    assert_equal "valuation", excerpt[:text][offset, length]
    assert_not_includes excerpt[:text], "\n"
  end

  test "a match only in the title gives no excerpt rather than the opening words" do
    result = search(query: "board").results.first
    assert_equal @recording.id, result.record.id
    assert_empty result.excerpts
  end

  test "a transcript is not searched until the recording is ready" do
    @recording.update_columns(status: "transcribing")
    assert_empty search(query: "granttree").results
    # The title still is.
    assert_equal 1, search(query: "board").results.size
  end

  test "discarded and deleted items, and other accounts, are never found" do
    other = accounts(:another_team).whiteboards.create!(name: "Elsewhere", content: "bach partita")
    @note.soft_delete!
    assert_empty search(query: "bach").results
    assert other.persisted?

    @file.discard!
    assert_equal [ "recording" ], search(query: "valuation").results.map(&:kind)
  end

  test "tags filter, all of them, and can be searched without words" do
    @recording.change_tags!(by: @user, add: [ "GrantTree", "life" ])
    @file.change_tags!(by: @user, add: [ "life" ])

    assert_equal %w[file recording], search(tags: [ "life" ]).results.map(&:kind).sort
    assert_equal [ "recording" ], search(tags: %w[life granttree]).results.map(&:kind)
    assert_equal [ "file" ], search(query: "valuation", tags: [ "life" ], kinds: [ "file" ]).results.map(&:kind)
    assert_equal %w[granttree life], search(tags: %w[life granttree]).results.first.tags
    assert_empty search(tags: [ "nowhere" ]).results
  end

  test "a recording is dated by when it was recorded, when that's known" do
    @recording.update_columns(recorded_at: Time.zone.parse("2024-03-01 10:00"))
    result = search(query: "granttree").results.sole
    assert_equal Time.zone.parse("2024-03-01 10:00"), result.date
    assert_equal %w[file recording], search(query: "valuation").results.map(&:kind)
  end

  test "newest first by default, pages of twenty" do
    25.times { |i| @account.whiteboards.create!(name: "Page #{i}", content: "repeated word") }
    first = search(query: "repeated")
    assert_equal 20, first.results.size
    assert_equal 1, first.next_page
    dates = first.results.map(&:date)
    assert_equal dates.sort.reverse, dates

    second = search(query: "repeated", page: "1")
    assert_equal 5, second.results.size
    assert_nil second.next_page
    assert_empty first.results.map { |r| r.record.id } & second.results.map { |r| r.record.id }
  end

  test "bad input is refused plainly" do
    assert_raises(FieldSearch::Invalid) { search(query: "") }
    assert_raises(FieldSearch::Invalid) { search(query: "!!!") }
    assert_raises(FieldSearch::Invalid) { search(query: "x" * 201) }
    assert_raises(FieldSearch::Invalid) { search(query: "a", kinds: [ "chat" ]) }
    assert_raises(FieldSearch::Invalid) { search(query: "a", sort: "oldest") }
    assert_raises(FieldSearch::Invalid) { search(query: "a", page: "-1") }
    assert_raises(FieldSearch::Invalid) { search(query: "a", page: "two") }
  end

  test "SQL-looking queries are just words" do
    assert_empty search(query: "'); DROP TABLE whiteboards; --").results
    assert Whiteboard.exists?(@note.id)
  end

  # tsvector is capped at 1 MB and a generated column over it would make the
  # row's own write fail. Distinct hyphenated tokens are the densest text we
  # found (3.8 bytes of vector per character): writes must still succeed.
  test "the densest text we know of can still be written, and is searched up to the cap" do
    dense = (1..120_000).map { |i| "a#{i}-b#{i}" }.join(" ")
    assert_operator dense.length, :>, 1_000_000

    @recording.update!(transcript_text: dense, note: dense.first(FieldRecording::MAX_NOTE_LENGTH))
    @file.update_columns(extracted_text: dense)
    @note.update_columns(content: dense)

    assert_equal 1, search(query: "a2-b2", kinds: [ "recording" ]).results.size
    assert_empty search(query: "a119999-b119999", kinds: [ "file" ]).results
  end

  # Mira's repro (PR #262, round two): 4-byte alphabetic characters in
  # hyphenated compounds. 180,000 characters of it made a 1.2 MB vector under a
  # character budget; the byte budget has to hold it.
  test "dense four-byte Unicode can still be written" do
    letters = (0x10000..0x10FFFF).lazy.map { |code| code.chr(Encoding::UTF_8) }.select { |char| char.match?(/\A[[:alpha:]]\z/) }.first(90_000)
    dense = letters.each_slice(8).map { |slice| slice.join("-") }.join(" ")
    assert_operator dense.bytesize, :>, 400_000

    @recording.update!(transcript_text: dense)
    @file.update_columns(extracted_text: dense)
    @note.update_columns(content: dense)
    first = letters.first(8).join("-")
    assert_equal [ @recording.id ], search(query: "\"#{first}\"", kinds: [ "recording" ]).results.map { |r| r.record.id }
  end

  test "a file is found by its filename even with a different title" do
    file = @account.field_files.create!(title: "Receipt", uploaded_by: @user,
      file: Rack::Test::UploadedFile.new(file_fixture("test.txt"), "text/plain", original_filename: "orchid-invoice.txt"))
    assert_equal [ file.id ], search(query: "orchid").results.map { |r| r.record.id }
    assert_equal [ file.id ], search(query: "orchid invoice").results.map { |r| r.record.id }
  end

  test "a title that is a filename is found by its words, and dotted names still match themselves" do
    @recording.update!(title: "2024-11-02_zar-standup.m4a")
    assert_equal [ @recording.id ], search(query: "zar standup", kinds: [ "recording" ]).results.map { |r| r.record.id }
    @note.update!(name: "node.js pitch")
    assert_equal [ @note.id ], search(query: "node.js").results.map { |r| r.record.id }
  end

  test "parse_fragment collapses whitespace and keeps offsets exact" do
    parsed = FieldSearch.parse_fragment("  one\n\n\u0002two\u0003  three \u0002four\u0003")
    assert_equal "one two three four", parsed[:text]
    assert_equal [ [ 4, 3 ], [ 14, 4 ] ], parsed[:matches]
  end

  private

  def search(**options) = FieldSearch.new(account: @account, **options).call

  def upload
    Rack::Test::UploadedFile.new(file_fixture("test.txt"), "text/plain")
  end

end
