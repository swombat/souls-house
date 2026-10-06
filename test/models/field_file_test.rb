require "test_helper"

class FieldFileTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
  end

  def upload(name = "test.txt", type = "text/plain")
    Rack::Test::UploadedFile.new(file_fixture(name), type)
  end

  test "title defaults to the filename" do
    file = @account.field_files.create!(file: upload, uploaded_by: @user)
    assert_equal "test.txt", file.title
    assert_equal "human", file.uploader_kind
  end

  test "a file is required" do
    file = @account.field_files.new(title: "Nothing attached")
    assert_not file.valid?
    assert_includes file.errors[:file], "must be attached"
  end

  test "files over the limit are refused before saving" do
    file = @account.field_files.new(title: "Too big", file: upload)
    file.file.blob.byte_size = FieldFile::MAX_FILE_SIZE + 1
    assert_not file.valid?
    assert_match(/less than 100MB/, file.errors[:file].first)
  end

  test "the why-line is bounded" do
    file = @account.field_files.new(file: upload, note: "x" * (FieldFile::MAX_NOTE_LENGTH + 1))
    assert_not file.valid?
    assert file.errors[:note].any?
  end

  test "residents are named as residents" do
    agent = agents(:research_assistant)
    file = @account.field_files.create!(file: upload, uploaded_by: agent)
    assert_equal "resident", file.uploader_kind
    assert_equal agent.name, file.uploader_name
    assert file.uploaded_by_agent?(agent)
    assert_not file.uploaded_by_agent?(agents(:other_account_agent))
  end

end
