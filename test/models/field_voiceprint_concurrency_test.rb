require "test_helper"
require "support/field_recording_helpers"

# A barrier inside delete-name, after it has taken the account lock and
# gathered its recordings. Inert unless a test sets the hook.
module DeletePause
  mattr_accessor :hook

  private

  def forget_locked!
    DeletePause.hook&.call
    super
  end
end
FieldVoice.prepend(DeletePause)

# Forget racing a print write-back (spec §11, C): if the forget commits first,
# no print survives; whichever wins, a forgotten voice ends with no print.
class FieldVoiceprintConcurrencyTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  self.use_transactional_tests = false

  setup do
    @last_blob_id = ActiveStorage::Blob.maximum(:id).to_i
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
    # Enrolment samples are purged later, by a job these tests never run, and
    # nothing rolls this database back: purge them here, or they outlive the test.
    ActiveStorage::Blob.where("id > ?", @last_blob_id).find_each(&:purge)
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

  def dispatched_enrolment
    enrolment = nil
    FieldVoiceprints::Sample.stub(:cut, ->(_r, _s, &block) { Tempfile.create([ "s", ".wav" ]) { |f| block.call(f.path) } }) do
      enrolment = FieldVoiceprints::Enrolments.start!(@speaker, by: @user)
    end
    FieldVoiceprints::Enrolments.dispatch!(enrolment, client: FakePyannote.new)
  end

  test "deleting a name racing a write-back never leaves a print on the deleted voice" do
    with_recognition(@account) do
      enrolment = dispatched_enrolment
      concurrently(2) do |i|
        i.zero? ? FieldVoice.find(@voice.id).delete_identity! : FieldVoiceprints::Enrolments.write_back!(enrolment.id, "PRINT")
      end
      assert @voice.reload.discarded?
      assert_nil FieldVoiceprint.find_by(field_voice_id: @voice.id)
    end
  end

  test "un-naming racing a write-back: either the print predates the correction or nothing is stored" do
    with_recognition(@account) do
      enrolment = dispatched_enrolment
      results = concurrently(2) do |i|
        i.zero? ? FieldRecordingSpeaker.find(@speaker.id).unname! : FieldVoiceprints::Enrolments.write_back!(enrolment.id, "PRINT")
      end
      assert_nil @speaker.reload.field_voice
      stored = FieldVoiceprint.find_by(field_voice_id: @voice.id)
      assert_equal results.last == true, stored.present?, "a print exists only if its write-back committed before the un-name"
    end
  end

  # Mira's interleaving on 7a19009: delete has gathered its recordings and is
  # mid-way; a request names a speaker in a recording that wasn't linked yet.
  # Naming now waits on the account lock, then finds the voice discarded.
  test "naming a previously unrelated recording while delete-name is mid-way leaves no stale name" do
    other = long_ready_recording(account: @account, user: @user)
    other_speaker = other.speakers.first
    paused, release = Queue.new, Queue.new
    DeletePause.hook = -> { paused << true; release.pop }
    begin
      deleter = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { FieldVoice.find(@voice.id).delete_identity! }
      end
      paused.pop # delete holds the account lock and has gathered its recordings

      namer = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          FieldRecordingSpeaker.find(other_speaker.id).name_as!(@voice, by: @user)
          :named
        rescue ActiveRecord::RecordNotFound
          :refused
        end
      end
      refute namer.join(0.5), "naming must wait for the delete, not link around it"

      release << true
      deleter.value
      assert_equal :refused, namer.value
    ensure
      DeletePause.hook = nil
    end

    assert @voice.reload.discarded?
    assert_nil other_speaker.reload.field_voice_id
    refute_includes other.reload.transcript_text.to_s, "Tomás"
    refute_includes @recording.reload.transcript_text.to_s, "Tomás"
  end

  test "a voice resolved before delete-name can't be linked after it" do
    other = long_ready_recording(account: @account, user: @user)
    stale = FieldVoice.find(@voice.id)
    FieldVoice.find(@voice.id).delete_identity!

    assert_raises(ActiveRecord::RecordNotFound) { other.speakers.first.name_as!(stale, by: @user) }
    assert_nil other.speakers.first.reload.field_voice_id
    refute_includes other.reload.transcript_text.to_s, "Tomás"
  end

  test "a stale speaker object doesn't reuse a decision generation" do
    stale = FieldRecordingSpeaker.find(@speaker.id)
    FieldRecordingSpeaker.find(@speaker.id).unname!
    before = @speaker.reload.decision_generation
    stale.name_as!(@voice, by: @user)
    assert_equal before + 1, @speaker.reload.decision_generation
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
