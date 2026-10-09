require "test_helper"
require "support/field_recording_helpers"

class FieldTagTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @user = users(:user_1)
    @resident = agents(:research_assistant)
    @account = @resident.account
    @file = @account.field_files.create!(file: upload, uploaded_by: @user)
    @note = @account.whiteboards.create!(name: "Plans", content: "x")
  end

  test "names fold: case, spaces, a leading hash" do
    assert_equal [ "life story" ], @file.change_tags!(by: @user, add: [ "  #Life   Story " ])
    assert_equal [ "life story" ], @note.change_tags!(by: @resident, add: [ "LIFE STORY" ])
    assert_equal 1, @account.field_tags.kept.count
  end

  test "add, remove and set; removal keeps who did it" do
    @file.change_tags!(by: @user, add: %w[zar life])
    assert_equal %w[life zar], @file.tag_names

    @file.change_tags!(by: @resident, remove: [ "zar" ])
    assert_equal %w[life], @file.tag_names
    removed = FieldTagging.discarded.sole
    assert_equal @resident, removed.discarded_by
    assert_equal @user, removed.tagged_by

    assert_equal %w[music souls.house], @file.change_tags!(by: @user, set: %w[music souls.house])
  end

  test "limits are enforced" do
    assert_raises(FieldTag::Invalid) { @file.change_tags!(by: @user, add: [ "x" * 51 ]) }
    assert_raises(FieldTag::Invalid) { @file.change_tags!(by: @user, add: (1..33).map { |i| "t#{i}" }) }
    assert_raises(FieldTag::Invalid) { @file.change_tags!(by: @user, add: [ "a" ], remove: [ "a" ]) }
    assert_raises(FieldTag::Invalid) { @file.change_tags!(by: @user, add: [ 1 ]) }
    assert_empty @file.tag_names
  end

  test "rename everywhere, conflict, merge" do
    @file.change_tags!(by: @user, add: [ "Life" ])
    @note.change_tags!(by: @user, add: %w[life-anna personal])
    life = @account.field_tags.find_by!(name: "life")

    life.rename!("Living", by: @user)
    assert_equal [ "living" ], @file.tag_names

    personal = @account.field_tags.find_by!(name: "personal")
    error = assert_raises(FieldTag::Conflict) { personal.rename!("living", by: @user) }
    assert_equal life, error.existing

    @file.change_tags!(by: @user, add: [ "personal" ])
    target = personal.rename!("living", by: @user, merge: true)
    assert_equal life, target
    assert personal.reload.discarded?
    assert_equal [ "living" ], @file.tag_names
    assert_equal %w[life-anna living], @note.tag_names
  end

  test "deleting a tag hides it everywhere, keeps the rows, and the name can be used again" do
    @file.change_tags!(by: @user, add: [ "zar" ])
    tag = @account.field_tags.find_by!(name: "zar")
    tag.discard_by!(@user)

    assert_empty @file.tag_names
    assert_equal @user, tag.reload.discarded_by
    assert FieldTagging.exists?(field_tag_id: tag.id)

    @file.change_tags!(by: @user, add: [ "zar" ])
    assert_equal [ "zar" ], @file.tag_names
    assert_not_equal tag.id, @account.field_tags.kept.find_by!(name: "zar").id
  end

  test "counts only items still in the Field" do
    @file.change_tags!(by: @user, add: [ "zar" ])
    @note.change_tags!(by: @user, add: [ "zar" ])
    @note.soft_delete!
    tag = @account.field_tags.find_by!(name: "zar")
    assert_equal({ tag.id => 1 }, FieldTag.item_counts(@account))
  end

  private

  def upload
    Rack::Test::UploadedFile.new(file_fixture("test.txt"), "text/plain")
  end

end
