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

# Forget, delete-name and un-name racing a sample being learned (spec
# 2026-10-19 §9): whichever commits first, the voice or speaker a person
# took back ends with no sample and no print.
class FieldVoiceprintConcurrencyTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  self.use_transactional_tests = false

  setup do
    @last_blob_id = ActiveStorage::Blob.maximum(:id).to_i
    @cutover = Setting.instance.field_naming_cutover_at
    @account = Account.create!(name: "Voice race #{SecureRandom.hex(4)}", account_type: "team")
    @user = users(:user_1)
    @recording = long_ready_recording(account: @account, user: @user)
    @speaker = @recording.speakers.first
    @voice = @account.field_voices.create!(name: "Tomás")
    @speaker.name_as!(@voice, by: @user)
  end

  teardown do
    Setting.instance.update!(field_naming_cutover_at: @cutover) # nothing rolls with_recognition back here
    FieldVoiceprint.where(account: @account).delete_all
    FieldVoiceSample.where(account: @account).delete_all
    recordings = FieldRecording.where(account: @account)
    FieldRecordingSpeaker.where(field_recording: recordings).update_all(field_voice_id: nil, recognised_voice_id: nil)
    FieldVoice.where(account: @account).delete_all
    FieldRecordingSpeaker.where(field_recording: recordings).delete_all
    FieldRecordingDispatch.where(field_recording: recordings).delete_all
    FieldRecordingReservation.where(account: @account).delete_all
    recordings.each { |r| r.audio.purge }
    recordings.delete_all
    @account.destroy!
    # Nothing rolls this database back: purge any blob made here, or it
    # outlives the test.
    ActiveStorage::Blob.where("id > ?", @last_blob_id).find_each(&:purge)
  end

  # The snapshot a naming queues, learned with a fake cut and embedding.
  def learn(snapshot)
    FieldVoiceprints::Learning.learn!(snapshot, client: FakeVoiceEmbeddings.new({ default: voice_vector(1) }))
  end

  def snapshot
    FieldVoiceprints::Learning.snapshot_for(FieldRecordingSpeaker.find(@speaker.id)).tap { |taken| assert taken }
  end

  def with_fake_cut(&)
    FieldVoiceprints::Sample.stub(:cut, ->(_r, _s, &block) { Tempfile.create([ "s", ".wav" ]) { |f| block.call(f.path) } }, &)
  end

  test "forget racing a sample being learned never leaves a print or sample on a forgotten voice" do
    with_recognition(@account) do
      with_fake_cut do
        taken = snapshot
        results = concurrently(2) { |i| i.zero? ? FieldVoice.find(@voice.id).forget! : learn(taken) }
        assert_includes [ :learned, :stale ], results.last
      end
      assert_not @voice.reload.remember?
      assert_nil FieldVoiceprint.find_by(field_voice_id: @voice.id)
      assert_equal 0, FieldVoiceSample.where(field_voice_id: @voice.id).count
    end
  end

  test "deleting a name racing a sample being learned never leaves a print on the deleted voice" do
    with_recognition(@account) do
      with_fake_cut do
        taken = snapshot
        concurrently(2) { |i| i.zero? ? FieldVoice.find(@voice.id).delete_identity! : learn(taken) }
      end
      assert @voice.reload.discarded?
      assert_nil FieldVoiceprint.find_by(field_voice_id: @voice.id)
      assert_equal 0, FieldVoiceSample.where(field_voice_id: @voice.id).count
    end
  end

  test "un-naming racing a sample being learned: whichever lands first, no sample of the speaker stays" do
    with_recognition(@account) do
      with_fake_cut do
        taken = snapshot
        concurrently(2) { |i| i.zero? ? FieldRecordingSpeaker.find(@speaker.id).unname! : learn(taken) }
      end
      assert_nil @speaker.reload.field_voice
      assert_equal 0, FieldVoiceSample.where(field_recording_speaker_id: @speaker.id).count
      assert_nil FieldVoiceprint.find_by(field_voice_id: @voice.id), "a print built only from that sample goes with it"
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
