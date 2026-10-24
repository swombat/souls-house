require "test_helper"
require "action_cable/test_helper"

class FieldActivityBroadcastingTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @account = accounts(:personal_account)
    @other_account = accounts(:existing_user_account)
    @user = users(:user_1)
  end

  %i[whiteboard file recording tweet song tag tagging].each do |kind|
    test "#{kind} emits one content-free refresh only after each committed lifecycle change" do
      record = build_record(kind)

      assert_refresh_after_commit { record.save! }
      assert_refresh_after_commit { update_record(record) }
      assert_refresh_after_commit { record.destroy! }
    end

    test "#{kind} does not emit a refresh for rolled back create update or destroy" do
      record = build_record(kind)
      assert_rollback_without_refresh { record.save! }
      assert_not record.persisted?

      record.save!
      original_updated_at = record.updated_at
      assert_rollback_without_refresh { update_record(record) }
      assert_equal original_updated_at, record.reload.updated_at

      assert_rollback_without_refresh { record.destroy! }
      assert record.class.exists?(record.id)
    end

    test "#{kind} never refreshes another accounts Field" do
      record = build_record(kind)
      assert_no_broadcasts(stream(@other_account)) do
        record.save!
        update_record(record)
        record.destroy!
      end
    end
  end

  %i[whiteboard file recording tweet song].each do |kind|
    test "#{kind} respects skip_broadcast on create update and destroy" do
      record = build_record(kind)
      record.skip_broadcast = true
      assert_no_broadcasts(stream) do
        record.save!
        update_record(record)
        record.destroy!
      end
    end

    test "#{kind} refreshes on discard and restore" do
      record = build_record(kind)
      record.save!
      if kind == :whiteboard
        assert_refresh_after_commit { record.soft_delete! }
        assert_refresh_after_commit { record.restore! }
      else
        assert_refresh_after_commit { record.discard! }
        assert_refresh_after_commit { record.undiscard! }
      end
    end
  end

  test "derived extraction and summary writes refresh through the existing explicit broadcast path" do
    file = build_record(:file)
    file.save!

    assert_refresh do
      file.update_columns(extracted_text: "Locally extracted words", text_extracted_at: Time.current)
      file.send(:broadcast_refresh)
    end
    assert_refresh do
      file.update_columns(summary_short: "Locally supplied summary", summarized_at: Time.current)
      file.send(:broadcast_refresh)
    end

    file.skip_broadcast = true
    assert_no_broadcasts(stream) { file.send(:broadcast_refresh) }
  end

  %i[tag tagging].each do |kind|
    test "#{kind} explicit refresh and removal work without Broadcastable super methods" do
      record = build_record(kind)
      record.save!

      assert_refresh { record.send(:broadcast_refresh) }
      assert_refresh { record.send(:broadcast_removal) }
    end
  end

  test "optional super preserves item record markers and skip behavior" do
    file = build_record(:file)
    file.save!
    record_stream = "FieldFile:#{file.obfuscated_id}"

    assert_broadcasts(record_stream, 1) do
      assert_refresh { file.send(:broadcast_refresh) }
    end
    assert_broadcasts(record_stream, 1) do
      assert_refresh { file.send(:broadcast_removal) }
    end

    file.skip_broadcast = true
    assert_no_broadcasts(record_stream) do
      assert_no_broadcasts(stream) do
        file.send(:broadcast_refresh)
        file.send(:broadcast_removal)
      end
    end
  end

  test "tag add remove rename merge and discard refresh without a parent item edit" do
    note = build_record(:whiteboard)
    note.save!
    original_updated_at = note.updated_at

    assert_field_refresh { note.change_tags!(by: @user, add: [ "life" ]) }
    life = @account.field_tags.kept.find_by!(name: "life")
    assert_refresh_after_commit { life.rename!("living", by: @user) }
    assert_refresh_after_commit { note.change_tags!(by: @user, remove: [ "living" ]) }
    assert_refresh_after_commit { note.change_tags!(by: @user, add: [ "living" ]) }

    assert_field_refresh { note.change_tags!(by: @user, add: [ "personal" ]) }
    personal = @account.field_tags.kept.find_by!(name: "personal")
    assert_field_refresh { personal.rename!("living", by: @user, merge: true) }
    assert_refresh_after_commit { life.discard_by!(@user) }

    assert_equal original_updated_at, note.reload.updated_at
  end

  %i[tag tagging].each do |kind|
    test "#{kind} discards and restores refresh" do
      record = build_record(kind)
      record.save!
      assert_refresh_after_commit { record.discard! }
      assert_refresh_after_commit { record.undiscard! }
    end
  end

  test "chat messages and chat edits never refresh Field" do
    assert_no_broadcasts(stream) do
    chat = @account.chats.create!(title: "Not Field", manual_responses: true,
      agents: [ agents(:research_assistant) ])
      message = chat.messages.create!(role: "user", user: @user, content: "Conversation only")
      message.update!(content: "Still conversation only")
      message.discard!
      chat.update!(title: "Still not Field")
    end
  end

  private

  def stream(account = @account)
    "FieldActivity:#{account.obfuscated_id}"
  end

  def assert_refresh
    messages = capture_broadcasts(stream) { yield }
    assert_equal [ { "action" => "refresh" } ], messages
  end

  def assert_refresh_after_commit
    assert_refresh do
      ApplicationRecord.transaction do
        assert_no_broadcasts(stream) { yield }
      end
    end
  end

  # Adding a new tag or merging can commit several producer records. Every
  # marker is still content-free; the client coalesces these invalidations.
  def assert_field_refresh
    messages = capture_broadcasts(stream) do
      ApplicationRecord.transaction do
        assert_no_broadcasts(stream) { yield }
      end
    end
    assert_not_empty messages
    assert messages.all? { |message| message == { "action" => "refresh" } }
  end

  def assert_rollback_without_refresh
    assert_no_broadcasts(stream) do
      ApplicationRecord.transaction(requires_new: true) do
        yield
        raise ActiveRecord::Rollback
      end
    end
  end

  def update_record(record)
    # Make an ordinary update without invoking extraction or any provider.
    case record
    when Whiteboard then record.update!(content: "Updated local words")
    when FieldTag then record.update!(name: "renamed")
    when FieldTagging then record.update!(discarded_at: Time.current, discarded_by: @user)
    when FieldTweet then record.update!(text: "Updated local post")
    else record.update!(title: "Updated local title")
    end
  end

  def build_record(kind)
    case kind
    when :whiteboard
      @account.whiteboards.new(name: "Local note", content: "Local words")
    when :file
      @account.field_files.new(title: "Local file", file: Rack::Test::UploadedFile.new(file_fixture("test_image.png"), "image/png"))
    when :recording
      @account.field_recordings.new(title: "Local recording",
        audio: Rack::Test::UploadedFile.new(file_fixture("test_audio.webm"), "audio/webm"))
    when :tweet
      @account.field_tweets.new(provider_tweet_id: "385", author_handle: "local",
        text: "Local post", posted_at: Time.current, fetched_at: Time.current, url: "https://example.com/post/385")
    when :song
      @account.field_songs.new(title: "Local song", links: [ "https://example.com/song" ])
    when :tag
      @account.field_tags.new(name: "life", created_by: @user)
    when :tagging
      tag = @account.field_tags.create!(name: "life", created_by: @user)
      note = @account.whiteboards.create!(name: "Tagged note", content: "Local words")
      @account.field_taggings.new(field_tag: tag, taggable: note, tagged_by: @user)
    end
  end

end
