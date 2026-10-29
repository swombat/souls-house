require "test_helper"
require "support/field_recording_helpers"

class FieldRecordingNeighboursTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @account.field_recordings.update_all(discarded_at: Time.current)
  end

  test "previous and next follow the Recordings list; the waiting pair skips recordings with nobody left to name" do
    oldest = ready_recording(account: @account, user: @user, title: "Oldest", recorded_at: Time.zone.parse("2026-10-01 10:00"))
    named = ready_recording(account: @account, user: @user, title: "All named", recorded_at: Time.zone.parse("2026-10-02 10:00"))
    middle = ready_recording(account: @account, user: @user, title: "Middle", recorded_at: Time.zone.parse("2026-10-03 10:00"))
    # Same moment as Middle: the list puts the higher id first, so it is newer here.
    noise = ready_recording(account: @account, user: @user, title: "Set aside", recorded_at: Time.zone.parse("2026-10-03 10:00"))
    gone = ready_recording(account: @account, user: @user, title: "Deleted", recorded_at: Time.zone.parse("2026-10-04 10:00"))
    gone.update_columns(discarded_at: Time.current)

    voice = @account.field_voices.create!(name: "Ana")
    named.speakers.each { |speaker| speaker.name_as!(voice, by: @user) }
    noise.speakers.each { |speaker| speaker.ignore!(by: @user) }

    around = FieldRecordingNeighbours.new(middle.reload).as_json
    assert_equal "Set aside", around[:previous][:title]
    assert_equal "All named", around[:next][:title]
    assert_nil around[:previous_waiting], "every speaker set aside: nothing to name"
    assert_equal "Oldest", around[:next_waiting][:title]
    assert_equal Rails.application.routes.url_helpers.account_field_recording_path(@account, oldest), around[:next_waiting][:url]

    newest = FieldRecordingNeighbours.new(noise.reload).as_json
    assert_nil newest[:previous], "a deleted recording isn't a neighbour"
    assert_equal "Middle", newest[:next][:title]
    assert_equal "Middle", newest[:next_waiting][:title]

    last = FieldRecordingNeighbours.new(oldest.reload).as_json
    assert_nil last[:next]
    assert_nil last[:next_waiting]
    assert_equal "All named", last[:previous][:title]
    assert_equal "Middle", last[:previous_waiting][:title]
  end

end
