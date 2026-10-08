require "test_helper"
require "support/field_recording_helpers"

# Forget racing a print write-back (spec §11, C): if the forget commits first,
# no print survives; whichever wins, a forgotten voice ends with no print.
class FieldVoiceprintConcurrencyTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Voice race #{SecureRandom.hex(4)}", account_type: "team")
    @user = users(:user_1)
    @recording = long_ready_recording(account: @account, user: @user)
    @speaker = @recording.speakers.first
    @voice = @account.field_voices.create!(name: "Tomás")
    @speaker.name_as!(@voice, by: @user)
  end

  teardown do
    FieldVoiceprint.where(account: @account).delete_all
    FieldVoiceEnrolment.where(account: @account).find_each(&:destroy!)
    recordings = FieldRecording.where(account: @account)
    FieldRecordingSpeaker.where(field_recording: recordings).update_all(field_voice_id: nil, recognised_voice_id: nil)
    FieldVoice.where(account: @account).delete_all
    FieldRecordingSpeaker.where(field_recording: recordings).delete_all
    FieldRecordingDispatch.where(field_recording: recordings).delete_all
    FieldRecordingReservation.where(account: @account).delete_all
    recordings.each { |r| r.audio.purge }
    recordings.delete_all
    @account.destroy!
  end

  test "forget racing a write-back never leaves a print on a forgotten voice" do
    enrolment = nil
    with_recognition(@account) do
      FieldVoiceprints::Sample.stub(:cut, ->(_r, _s, &block) { Tempfile.create([ "s", ".wav" ]) { |f| block.call(f.path) } }) do
        enrolment = FieldVoiceprints::Enrolments.start!(@speaker, by: @user)
      end
      FieldVoiceprints::Enrolments.dispatch!(enrolment, client: FakePyannote.new)

      results = concurrently(2) do |i|
        i.zero? ? FieldVoice.find(@voice.id).forget! : FieldVoiceprints::Enrolments.write_back!(enrolment.id, "PRINT")
      end

      if results.last == true # write-back won; then the forget removed it
        assert_nil FieldVoiceprint.find_by(field_voice_id: @voice.id)
      else
        assert_nil FieldVoiceprint.find_by(field_voice_id: @voice.id)
      end
    end
  end

  private

  def concurrently(count)
    ready, start = Queue.new, Queue.new
    threads = count.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          yield i
        end
      end
    end
    count.times { ready.pop }
    count.times { start << true }
    threads.map(&:value)
  end

end
