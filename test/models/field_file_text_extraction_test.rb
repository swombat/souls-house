require "test_helper"

class FieldFileTextExtractionTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

  setup do
    @account = agents(:research_assistant).account
    @user = users(:user_1)
  end

  test "a text file's words become searchable after the job runs" do
    file = perform_enqueued_jobs do
      @account.field_files.create!(file: text_upload("2024-03-01 zar standup.md", "Brandon and Sebastian\u0000 argued about the roadmap"),
        uploaded_by: @user)
    end
    file.reload
    assert_equal "Brandon and Sebastian argued about the roadmap", file.extracted_text
    assert file.text_extracted_at
    assert_equal [ file.id ], FieldSearch.new(account: @account, query: "sebastian roadmap").call.results.map { |r| r.record.id }
  end

  test "extraction tells an open Field page to refresh, without counting as an edit" do
    file = @account.field_files.create!(file: text_upload("plan.md", "the orchard plan"), uploaded_by: @user)
    updated_at = file.reload.updated_at
    assert_broadcasts("FieldFile:#{file.obfuscated_id}", 1) do
      assert_broadcasts("Account:#{@account.obfuscated_id}", 1) { file.extract_text! }
    end
    assert_equal updated_at, file.reload.updated_at
  end

  test "binary files and big files are not read" do
    assert_no_enqueued_jobs(only: FieldFiles::ExtractTextJob) do
      @account.field_files.create!(file: text_upload("photo.jpg", "\xFF\xD8\xFF".b, "image/jpeg"), uploaded_by: @user)
    end
    big = @account.field_files.new(file: text_upload("huge.txt", "a" * (FieldFile::TextExtraction::MAX_BYTES + 1)), uploaded_by: @user)
    assert_not big.text_extractable?
  end

  test "invalid UTF-8 is replaced, not refused" do
    file = @account.field_files.create!(file: text_upload("notes.txt", "caf\xE9 con leche".b), uploaded_by: @user)
    assert file.extract_text!
    assert_equal "caf� con leche", file.reload.extracted_text
  end

  private

  def text_upload(name, body, type = "text/plain")
    io = Tempfile.new([ "field", File.extname(name) ])
    io.binmode
    io.write(body)
    io.rewind
    Rack::Test::UploadedFile.new(io.path, type, original_filename: name)
  end

end
