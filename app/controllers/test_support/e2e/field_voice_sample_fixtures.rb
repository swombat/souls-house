module TestSupport::E2e::FieldVoiceSampleFixtures

  # Synthetic tones and persisted enrollment only. No speech, resident audio,
  # embedding service, recognition configuration or provider calls.
  def field_voice_sample_fixture
    account = Account.find(params.fetch(:account_id))
    raise ActiveRecord::RecordNotFound unless account.name.start_with?("E2E ")

    user = account.memberships.find_by!(role: "owner").user
    pcm = Array.new(64_000) do |index|
      frequency = [ 220, 880, 440, 660 ][index / 16_000]
      (8_000 * Math.sin(2 * Math::PI * frequency * index / 16_000)).round
    end.pack("s<*")
    wav = "RIFF".b + [ 36 + pcm.bytesize ].pack("V") + "WAVEfmt ".b +
      [ 16, 1, 1, 16_000, 32_000, 2, 16 ].pack("VvvVVvv") +
      "data".b + [ pcm.bytesize ].pack("V") + pcm
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(wav), filename: "synthetic-speaker-tones.wav", content_type: "audio/wav"
    )
    recording = account.field_recordings.create!(
      title: "Synthetic stored montage", uploaded_by: user, audio: blob,
      transcript_source: "vendor"
    )
    # Deliberately different from the stored montage and short speaker preview:
    # a player that reselects spans or serves the original recording must fail.
    recording.update_columns(status: "ready", ready_at: Time.current, duration_ms: 4_000,
      transcript_words: [
        { "k" => "w", "spk" => "speaker_0", "s" => 0, "e" => 4_000, "t" => "Synthetic tones" }
      ])
    speaker = recording.speakers.create!(
      label: "speaker_0", position: 0, talk_ms: 4_000, clip_start_ms: 0, clip_end_ms: 500
    )
    voice = account.field_voices.create!(name: "Synthetic sample voice")
    speaker.name_as!(voice, by: user)
    speaker.reload
    segments = [ [ 0, 1_000 ], [ 2_000, 3_500 ] ]
    digest = FieldVoiceSample.source_digest_for(speaker, segments)
    sample = FieldVoiceSample.new(
      account:, field_voice: voice, field_recording_speaker: speaker,
      field_recording_id: recording.id, speech_ms: 2_500, profile: "ecapa-synthetic",
      label_origin: "human", eligible: true, source_segments: segments, source_digest: digest
    )
    sample.vector = [ 1.0, 0.0, 0.0 ]
    sample.save!
    speaker.update!(sample_learning_status: "learned")
    voice.with_lock { FieldVoiceprints::Learning.rebuild!(voice) }
    expected_pcm = segments.map { |from, to| pcm.byteslice(from * 32, (to - from) * 32) }.join
    render json: {
      voice_param: voice.to_param, speaker_param: speaker.to_param, digest:, segments:,
      duration_ms: sample.speech_ms, pcm_bytes: expected_pcm.bytesize,
      pcm_sha256: Digest::SHA256.hexdigest(expected_pcm)
    }
  end

end
