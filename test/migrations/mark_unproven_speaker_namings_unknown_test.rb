require "test_helper"
require "support/field_recording_helpers"
require Rails.root.join("db/migrate/20261019120000_mark_unproven_speaker_namings_unknown")

# Provenance (spec 2026-10-19 §5): a naming nobody can attribute is unknown,
# never human, and no rollback or sweep promotes it.
class MarkUnprovenSpeakerNamingsUnknownTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @recording = long_ready_recording(account: @account, user: @user)
    @voice = @account.field_voices.create!(name: "Tomás")
  end

  def speakers_with(sources)
    sources.map do |source|
      speaker = @recording.speakers.create!(label: "speaker_x#{@recording.speakers.count}", position: @recording.speakers.count)
      speaker.update_columns(field_voice_id: @voice.id, naming_source: source, named_at: 1.day.ago)
      speaker
    end
  end

  test "up turns only human into unknown, and keeps machine and confirmed sources" do
    human, machine, suggestion, recognition = speakers_with(%w[human machine confirmed_suggestion confirmed_recognition])

    MarkUnprovenSpeakerNamingsUnknown.new.up

    assert_equal "unknown", human.reload.naming_source
    assert_equal "machine", machine.reload.naming_source
    assert_equal "confirmed_suggestion", suggestion.reload.naming_source
    assert_equal "confirmed_recognition", recognition.reload.naming_source
  end

  test "down refuses rather than promoting unknown to human" do
    unknown, = speakers_with(%w[unknown])
    assert_raises(ActiveRecord::IrreversibleMigration) { MarkUnprovenSpeakerNamingsUnknown.new.down }
    assert_equal "unknown", unknown.reload.naming_source
  end

  test "the cutover sweep marks only human namings from before old writers stopped" do
    old_writer, = speakers_with(%w[human])
    stopped = Time.current
    new_writer, = speakers_with(%w[human])
    new_writer.update_columns(named_at: stopped + 1.minute)
    machine, = speakers_with(%w[machine])

    assert_equal 1, FieldRecordingSpeaker.mark_unproven_namings_unknown!(before: stopped)

    assert_equal "unknown", old_writer.reload.naming_source
    assert_equal "human", new_writer.reload.naming_source
    assert_equal "machine", machine.reload.naming_source
  end

end
