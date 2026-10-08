require "test_helper"
require "support/field_recording_helpers"

class FieldVoiceTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
  end

  test "names are unique among kept voices in an account, ignoring case" do
    @account.field_voices.create!(name: "Priya")
    duplicate = @account.field_voices.new(name: " priya ")
    assert_not duplicate.valid?

    @account.field_voices.kept.first.discard!
    assert duplicate.valid?
    assert accounts(:another_team).field_voices.new(name: "Priya").valid?
  end

  test "a member's own voice is made once and found again" do
    voice = FieldVoice.for_member!(account: @account, user: @user, by: @user)
    assert_equal @user, voice.user
    assert_equal voice, FieldVoice.for_member!(account: @account, user: @user, by: @user)
  end

  test "a member's voice never absorbs an unlinked voice that shares the name" do
    base = @user.full_name.presence || @user.email_address.split("@").first
    stranger = @account.field_voices.create!(name: base)

    mine = FieldVoice.for_member!(account: @account, user: @user, by: @user)
    assert_not_equal stranger, mine
    assert_nil stranger.reload.user_id
    assert_match base, mine.name
  end

  test "renaming a voice re-renders every transcript that names it" do
    first = ready_recording(account: @account, user: @user)
    second = ready_recording(account: @account, user: @user)
    voice = @account.field_voices.create!(name: "Tomás")
    first.speakers.first.name_as!(voice, by: @user)
    second.speakers.last.name_as!(voice, by: @user)

    perform_enqueued_jobs { voice.update!(name: "Tomás García") }

    assert_match "Tomás García: hello", first.reload.transcript_text
    assert_match "Tomás García: there", second.reload.transcript_text
  end

end
