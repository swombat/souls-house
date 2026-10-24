require "test_helper"
require "stringio"
require "support/field_recording_helpers"

class FieldVoiceSamplesTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @voice = @account.field_voices.create!(name: "Standalone voice")
    @other = @account.field_voices.create!(name: "Another standalone voice")
  end

  def wav(seconds: 4, seed: 0)
    pcm = [ seed ].pack("s<") * (16_000 * seconds)
    "RIFF".b + [ pcm.bytesize + 36 ].pack("V") + "WAVEfmt " +
      [ 16, 1, 1, 16_000, 32_000, 2, 16 ].pack("VvvVVvv") +
      "data" + [ pcm.bytesize ].pack("V") + pcm
  end

  def upload(voice: @voice, bytes: wav, metadata: {}, by: @user)
    FieldVoiceSamples::Uploads.create!(voice:, by:, file: StringIO.new(bytes), metadata:)
  end

  def embedding_client(&during)
    Object.new.tap do |client|
      client.define_singleton_method(:embed) do |_bytes|
        during&.call
        FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: [ 1.0 ] + [ 0.0 ] * 191, profile: FieldVoiceprints::Profiles::ECAPA)
      end
    end
  end

  def learned_sample(**options)
    upload(**options).tap do |sample|
      assert_equal :learned, FieldVoiceSamples::Uploads.learn!(sample, client: embedding_client)
      sample.reload
    end
  end

  test "strict WAV inspection accepts exactly supported PCM and duration boundaries" do
    [ 4, 60 ].each do |seconds|
      bytes = wav(seconds:)
      assert_equal [ bytes, seconds * 1_000 ], FieldVoiceSamples::Wav.read!(StringIO.new(bytes))
    end
    assert_raises(FieldVoiceSamples::Invalid) { upload(bytes: wav(seconds: 3)) }
    assert_raises(FieldVoiceSamples::Invalid) { upload(bytes: wav(seconds: 61)) }
    assert_raises(FieldVoiceSamples::Invalid) { upload(bytes: "RIFF" * 600_000) }
    assert_raises(FieldVoiceSamples::Invalid) { upload(bytes: wav + "trailing") }
    assert_raises(FieldVoiceSamples::Invalid) { upload(bytes: wav.byteslice(0, 100)) }
    [ [ 20, [ 3 ].pack("v") ], [ 22, [ 2 ].pack("v") ], [ 24, [ 8_000 ].pack("V") ],
      [ 28, [ 16_000 ].pack("V") ], [ 32, [ 4 ].pack("v") ], [ 34, [ 8 ].pack("v") ] ].each do |offset, value|
      bytes = wav
      bytes[offset, value.bytesize] = value
      assert_raises(FieldVoiceSamples::Invalid) { upload(bytes:) }
    end
  end

  test "uploaded audio is retained exactly and creates no embedding or automatic enrollment" do
    bytes = wav(seed: 7)
    sample = upload(bytes:)
    assert sample.standalone?
    assert_nil sample.field_recording_id
    assert_equal bytes, sample.audio.download
    assert_equal Digest::SHA256.hexdigest(bytes), sample.content_sha256
    assert_equal 4_000, sample.speech_ms
    assert_equal "pending", sample.learning_status
    assert_nil sample.embedding
    assert_nil sample.vector
    assert_not sample.eligible?
    assert_not sample.manually_confirmed?
    assert sample.source_current?
    assert_equal sample.id, FieldVoiceSample.decode_id(sample.to_param)
    assert_raises(NotImplementedError) { sample.as_json }
  end

  test "account-wide identical bytes deduplicate but never silently change voice" do
    sample = upload
    assert_equal sample, upload
    assert_equal 1, @voice.samples.count
    assert_raises(FieldVoiceSamples::Conflict) { upload(voice: @other) }
    another = accounts(:team_account)
    if another
      other_voice = another.field_voices.create!(name: "Independent")
      assert_not_equal sample.id, upload(voice: other_voice).id
    end
  end

  test "source interval overlap deduplicates different cuts but adjacent spans do not" do
    metadata = { source_sha256: "a" * 64, start_ms: 100, end_ms: 4_100 }
    original = upload(metadata:)
    assert_equal original, upload(bytes: wav(seed: 2), metadata: metadata.merge(start_ms: 3_000, end_ms: 7_000))
    assert_raises(FieldVoiceSamples::Conflict) do
      upload(voice: @other, bytes: wav(seed: 3), metadata: metadata.merge(start_ms: 3_000, end_ms: 7_000))
    end
    adjacent = upload(bytes: wav(seed: 4), metadata: metadata.merge(start_ms: 4_100, end_ms: 8_100))
    assert_not_equal original, adjacent
    assert_equal original.source_group_key, adjacent.source_group_key
  end

  test "retry keys bind immutable requests including deduplicated aliases" do
    original = upload(metadata: { idempotency_key: "first" })
    assert_equal original, upload(metadata: { idempotency_key: "first" })
    assert_equal original, upload(metadata: { idempotency_key: "alias" })
    assert_equal original, upload(metadata: { idempotency_key: "alias" })
    assert_raises(FieldVoiceSamples::Conflict) { upload(bytes: wav(seed: 1), metadata: { idempotency_key: "first" }) }
    assert_raises(FieldVoiceSamples::Conflict) { upload(bytes: wav(seed: 2), metadata: { idempotency_key: "alias" }) }
    assert_raises(FieldVoiceSamples::Conflict) { upload(metadata: { idempotency_key: "alias", source_session: "changed" }) }
    original.remove!(digest: original.source_digest, by: @user)
    assert_equal original, upload(metadata: { idempotency_key: "first" })
    assert original.reload.removed_at
  end

  test "separate cuts of one original cannot leak into different session groups" do
    first = upload(metadata: { source_sha256: "c" * 64, source_session: "canonical" })
    second = upload(bytes: wav(seed: 9), metadata: { source_sha256: "c" * 64, source_session: "canonical" })
    assert_equal first.source_group_key, second.source_group_key
    assert_raises(FieldVoiceSamples::Conflict) do
      upload(bytes: wav(seed: 10), metadata: { source_sha256: "c" * 64, source_session: "different" })
    end
  end

  test "the account learning gate stops upload embedding before and after the service call" do
    sample = upload
    @account.update!(recognise_voices: false)
    forbidden = Object.new
    forbidden.define_singleton_method(:embed) { |_| raise "must not embed while off" }
    assert_equal :stale, FieldVoiceSamples::Uploads.learn!(sample, client: forbidden)
    @account.update!(recognise_voices: true)
    client = embedding_client { @account.update!(recognise_voices: false) }
    assert_equal :stale, FieldVoiceSamples::Uploads.learn!(sample, client:)
    assert_nil sample.reload.embedding
    assert_equal "pending", sample.learning_status
  end

  test "canonical groups cover identifiers mixed hashes and recording links" do
    recording = ready_recording(account: @account, user: @user)
    original = upload(metadata: { source_identifier: "identifier-only", source_session: "canonical",
      start_ms: 0, end_ms: 4_000 })
    assert_raises(FieldVoiceSamples::Conflict) do
      upload(bytes: wav(seed: 2), metadata: { source_identifier: "identifier-only", source_session: "different",
        start_ms: 4_000, end_ms: 8_000 })
    end
    mixed = upload(bytes: wav(seed: 3), metadata: { source_identifier: "identifier-only",
      source_sha256: "e" * 64, source_session: "canonical", start_ms: 4_000, end_ms: 8_000 })
    assert_equal original.source_group_key, mixed.source_group_key
    assert_raises(FieldVoiceSamples::Conflict) do
      upload(bytes: wav(seed: 4), metadata: { source_identifier: "identifier-only",
        source_session: "another", start_ms: 8_000, end_ms: 12_000 })
    end
    linked = upload(bytes: wav(seed: 5), metadata: { source_identifier: "linked-original",
      field_recording_id: recording.id, start_ms: 0, end_ms: 4_000 })
    assert_equal "account:#{@account.id}:recording:#{recording.id}", linked.source_group_key
    assert_raises(FieldVoiceSamples::Conflict) do
      upload(bytes: wav(seed: 6), metadata: { source_identifier: "linked-original",
        start_ms: 4_000, end_ms: 8_000 })
    end
  end

  test "metadata requires a valid source interval and an account-local recording" do
    [ { start_ms: 1 }, { start_ms: 5, end_ms: 4 }, { start_ms: 0, end_ms: 4_000 },
      { source_sha256: "invalid" }, { recorded_at: "yesterday" }, { source_session: "" } ].each do |metadata|
      assert_raises(FieldVoiceSamples::Invalid) { upload(metadata:) }
    end
    assert_raises(FieldVoiceSamples::Invalid) { upload(metadata: { field_recording_id: 0 }) }
    sample = upload(metadata: { recorded_at: "2026-10-22T12:30:00Z", source_identifier: "original.wav" })
    assert_equal Time.utc(2026, 10, 22, 12, 30), sample.recorded_at
  end

  test "recording dates mean midnight UTC and timestamps require an explicit offset" do
    date = upload(metadata: { recorded_at: "2020-02-03" })
    assert_equal Time.utc(2020, 2, 3), date.recorded_at
    zoned = upload(bytes: wav(seed: 1), metadata: { recorded_at: "2020-02-03T02:30:00+02:30" })
    assert_equal Time.utc(2020, 2, 3), zoned.recorded_at
    [ "2020-02-30", "2020-02-30T12:00:00Z", "2020-02-03T12:00:00",
      "2020-02-03 12:00:00Z", "2020-2-3", "" ].each do |recorded_at|
      assert_raises(FieldVoiceSamples::Invalid) { upload(metadata: { recorded_at: }) }
    end
  end

  test "known source intervals match actual WAV duration within one millisecond" do
    metadata = { source_identifier: "original.wav", start_ms: 1_000, end_ms: 5_000 }
    assert_equal 4_000, upload(metadata:).speech_ms
    assert_equal 4_000, upload(bytes: wav(seed: 1), metadata: metadata.merge(start_ms: 6_000, end_ms: 10_001)).speech_ms
    assert_equal 4_000, upload(bytes: wav(seed: 2), metadata: metadata.merge(start_ms: 11_000, end_ms: 14_999)).speech_ms
    [ 4_998, 5_002, 9_000 ].each do |end_ms|
      assert_raises(FieldVoiceSamples::Invalid) { upload(metadata: metadata.merge(end_ms:)) }
    end
  end

  test "pending admission counts failed rows and deduplication needs no new slot" do
    20.times do |index|
      upload(bytes: wav(seed: index)).update!(learning_status: "error")
    end
    assert_raises(FieldVoiceprints::Limits::Reached) { upload(bytes: wav(seed: 21)) }
    assert_equal @voice.samples.first, upload
    first = @voice.samples.first
    first.remove!(digest: first.source_digest, by: @user)
    assert upload(bytes: wav(seed: 21))
  end

  test "learning sends the exact retained WAV and requires a separate human confirmation" do
    sample = upload
    bytes = sample.audio.download
    client = embedding_client
    client.define_singleton_method(:embed) do |actual|
      raise "audio changed" unless actual == bytes
      FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: [ 1.0 ] + [ 0.0 ] * 191, profile: FieldVoiceprints::Profiles::ECAPA)
    end
    assert_equal :learned, FieldVoiceSamples::Uploads.learn!(sample, client:)
    sample.reload
    assert_not sample.eligible?
    assert_raises(FieldVoiceSamples::Invalid) { sample.review!(digest: sample.source_digest, by: nil, included: true) }
    sample.review!(digest: sample.source_digest, by: @user, included: true)
    assert sample.reload.manually_confirmed?
    assert sample.eligible?
    assert_equal @user, sample.confirmed_by
    assert_nil @voice.reload.voiceprint, "one confirmed sample does not enroll a print"
    assert_equal :stale, FieldVoiceSamples::Uploads.learn!(sample, client: embedding_client)
  end

  test "rejection retains confirmation and a machine can only reinclude that exact confirmed sample" do
    sample = learned_sample
    sample.review!(digest: sample.source_digest, by: @user, included: true)
    sample.review!(digest: sample.source_digest, by: nil, included: false)
    assert_not sample.reload.eligible?
    assert sample.manually_confirmed?
    assert sample.audio.attached?
    sample.review!(digest: sample.source_digest, by: nil, included: true)
    assert sample.reload.eligible?
    assert_raises(FieldVoiceSamples::Conflict) { sample.review!(digest: "stale", by: @user, included: true) }
  end

  test "reattribution clears confirmation changes digest and preserves audio" do
    sample = learned_sample
    sample.review!(digest: sample.source_digest, by: @user, included: true)
    digest = sample.source_digest
    sample.reattribute!(voice: @other, digest:, by: @user)
    assert_equal @other.id, sample.reload.field_voice_id
    assert_not sample.eligible?
    assert_not sample.manually_confirmed?
    assert_not_equal digest, sample.source_digest
    assert sample.source_current?
    assert sample.audio.attached?
    assert_raises(FieldVoiceSamples::Conflict) { sample.review!(digest:, by: @user, included: true) }
  end

  test "a voice move or removal during embedding makes its snapshot stale" do
    sample = upload
    client = embedding_client { sample.reattribute!(voice: @other, digest: sample.source_digest, by: @user) }
    assert_equal :stale, FieldVoiceSamples::Uploads.learn!(sample, client:)
    assert_nil sample.reload.embedding
    client = embedding_client { sample.remove!(digest: sample.source_digest, by: @user) }
    assert_equal :stale, FieldVoiceSamples::Uploads.learn!(sample, client:)
    assert_nil sample.reload.embedding
    assert sample.removed_at
  end

  test "forgetting a voice while embedding cannot recreate forgotten evidence" do
    sample = upload
    client = embedding_client { @voice.forget! }
    assert_equal :gone, FieldVoiceSamples::Uploads.learn!(sample, client:)
    assert_not FieldVoiceSample.exists?(sample.id)
    assert_nil @voice.reload.voiceprint
  end

  test "invalid service output cannot become an embedding" do
    sample = upload
    client = Object.new
    client.define_singleton_method(:embed) do |_bytes|
      FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: [ Float::NAN ], profile: "ecapa-test")
    end
    assert_raises(FieldVoiceSamples::Invalid) { FieldVoiceSamples::Uploads.learn!(sample, client:) }
    assert_nil sample.reload.embedding
  end

  test "linked recordings share a holdout group and discarded sources cannot teach or confirm" do
    recording = ready_recording(account: @account, user: @user)
    sample = learned_sample(metadata: { field_recording_id: recording.id, source_session: "cannot-override-recording" })
    speaker = recording.speakers.first
    legacy = FieldVoiceSample.new(account: @account, field_voice: @voice,
      field_recording: recording, field_recording_speaker: speaker)
    assert_equal legacy.source_group_key, sample.source_group_key
    recording.update_column(:discarded_at, Time.current)
    assert_not sample.reload.source_current?
    assert_equal :stale, FieldVoiceSamples::Uploads.learn!(sample, client: embedding_client)
    assert_raises(FieldVoiceSamples::Conflict) { sample.review!(digest: sample.source_digest, by: @user, included: true) }
    sample.remove!(digest: sample.source_digest, by: @user)
    assert sample.reload.removed_at
  end

  test "changing retained blob identity invalidates confirmation despite an unchanged claimed hash" do
    sample = learned_sample
    sample.review!(digest: sample.source_digest, by: @user, included: true)
    sample.audio.attach(io: StringIO.new(wav(seed: 10)), filename: "changed.wav", content_type: "audio/wav")
    assert_not sample.reload.source_current?
    assert_not sample.manually_confirmed?
    assert_raises(FieldVoiceSamples::Conflict) { sample.review!(digest: sample.source_digest, by: @user, included: true) }
  end

  test "exclusion frees pending capacity but keeps audio and allows later confirmation" do
    sample = learned_sample
    sample.review!(digest: sample.source_digest, by: nil, included: false)
    assert sample.reload.excluded?
    assert_not sample.manually_confirmed?
    assert_equal 0, FieldVoiceprints::Limits.pending_count(@voice)
    sample.review!(digest: sample.source_digest, by: @user, included: true)
    assert_not sample.reload.excluded?
    assert sample.manually_confirmed?
  end

  test "duplicate retry aliases are bounded and existing keys remain retryable" do
    sample = upload(metadata: { idempotency_key: "original" })
    sample.update_columns(idempotency_receipts: 100.times.to_h { |index| [ "key-#{index}", "fingerprint" ] })
    assert_raises(FieldVoiceSamples::Conflict) { upload(metadata: { idempotency_key: "overflow" }) }
    assert_equal sample, upload(metadata: { idempotency_key: "original" })
  end

end

# Real connections and committed, isolated rows: transactional fixtures would
# hide setup from the workers and cannot exercise the admission row locks.
class FieldVoiceSamplesConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Sample race #{SecureRandom.hex(6)}", account_type: "team")
    @user = users(:user_1)
    @voice = @account.field_voices.create!(name: "Source")
    @target = @account.field_voices.create!(name: "Target")
  end

  teardown do
    FieldVoiceprint.where(account: @account).delete_all
    samples = FieldVoiceSample.where(account: @account)
    samples.each { |sample| sample.audio.purge }
    samples.delete_all
    FieldVoice.where(account: @account).delete_all
    @account.destroy!
  end

  def upload(seed, voice: @voice)
    voice = FieldVoice.find_by!(id: voice.id)
    pcm = [ seed ].pack("s<") * 64_000
    bytes = "RIFF".b + [ pcm.bytesize + 36 ].pack("V") + "WAVEfmt " +
      [ 16, 1, 1, 16_000, 32_000, 2, 16 ].pack("VvvVVvv") +
      "data" + [ pcm.bytesize ].pack("V") + pcm
    FieldVoiceSamples::Uploads.create!(voice:, by: @user, file: StringIO.new(bytes))
  end

  def prepared(seed, confirmed: false)
    sample = upload(seed)
    sample.vector = [ 1.0 ] + [ 0.0 ] * 191
    sample.assign_attributes(profile: FieldVoiceprints::Profiles::ECAPA, learning_status: "learned")
    if confirmed
      sample.assign_attributes(eligible: true, confirmed_digest: sample.source_digest,
        confirmed_by: @user, confirmed_at: Time.current)
    end
    sample.save!
    sample
  end

  def race
    ready, start = Queue.new, Queue.new
    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          yield index
        rescue FieldVoiceprints::Limits::Reached
          :full
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each { |thread| assert thread.join(15), "sample admission deadlocked" }
    threads.map(&:value)
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end

  test "two uploads racing for the last pending slot admit only one" do
    19.times { |index| upload(index) }
    results = race { |index| upload(100 + index).id }
    assert_equal 1, results.count(:full)
    assert_equal 20, @voice.samples.count
    assert_equal 20, FieldVoiceprints::Limits.pending_count(@voice)
  end

  test "simultaneous identical uploads retain only one row and one audio" do
    results = race { upload(100).id }
    assert_equal 1, results.uniq.size
    assert_equal 1, @voice.samples.count
    assert_equal 1, ActiveStorage::Attachment.where(record: @voice.samples.first, name: "audio").count
  end

  test "two confirmations racing for the last active slot admit only one" do
    19.times { |index| prepared(index, confirmed: true) }
    candidates = [ prepared(100), prepared(101) ]
    results = race do |index|
      sample = FieldVoiceSample.find_by!(id: candidates[index].id)
      sample.review!(digest: sample.source_digest, by: @user, included: true).id
    end
    assert_equal 1, results.count(:full)
    assert_equal 20, @voice.samples.where(eligible: true).count
    assert_equal 1, candidates.count { |sample| sample.reload.eligible? }
  end

  test "two moves racing for the last destination pending slot admit only one" do
    19.times { |index| upload(index, voice: @target) }
    candidates = [ upload(100), upload(101) ]
    results = race do |index|
      sample = FieldVoiceSample.find_by!(id: candidates[index].id)
      sample.reattribute!(voice: @target, digest: sample.source_digest, by: @user).id
    end
    assert_equal 1, results.count(:full)
    assert_equal 20, @target.samples.count
    assert_equal 1, @voice.samples.count
  end

end
