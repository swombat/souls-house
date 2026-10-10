require "test_helper"
require "support/field_recording_helpers"
require Rails.root.join("db/migrate/20261010130000_retry_unsummarized_field_items")

class RetryUnsummarizedFieldItemsTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
  end

  def text_file(name)
    io = Tempfile.new([ "field", ".md" ])
    io.write("We replant the north orchard with pears in March.")
    io.rewind
    file = @account.field_files.create!(file: Rack::Test::UploadedFile.new(io.path, "text/plain", original_filename: name), uploaded_by: @user)
    file.update_columns(extracted_text: "We replant the north orchard with pears in March.", text_extracted_at: Time.current)
    file
  end

  test "gives unsummarised items their attempts back without freeing a claim still in flight" do
    now = Time.current
    in_flight = text_file("in-flight.md")
    in_flight.update_columns(summary_attempts: 2, summary_claimed_at: now - 1.minute)
    stale = text_file("stale.md")
    stale.update_columns(summary_attempts: FieldSummarizable::MAX_ATTEMPTS, summary_claimed_at: now - 1.hour)
    done = text_file("done.md")
    done.update_columns(summary_attempts: 1, summarized_at: now, summary_short: "Orchard replanting plan")
    recording = ready_recording(account: @account, user: @user)
    recording.update_columns(summary_attempts: FieldSummarizable::MAX_ATTEMPTS, summary_claimed_at: nil)

    RetryUnsummarizedFieldItems.new.up

    assert_equal 0, in_flight.reload.summary_attempts
    assert_in_delta (now - 1.minute).to_f, in_flight.summary_claimed_at.to_f, 1
    assert_equal 0, stale.reload.summary_attempts
    assert_equal 1, done.reload.summary_attempts
    assert_equal 0, recording.reload.summary_attempts

    # The live claim still protects its call; the stale one lapses as before.
    due = FieldFile.summary_due(now:)
    assert_not_includes due, in_flight
    assert_includes due, stale
    assert_not in_flight.claim_summary!(now:)
    assert FieldRecording.summary_due(now:).include?(recording)
  end

end
