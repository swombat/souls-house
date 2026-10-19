require "test_helper"
require "support/field_recording_helpers"

# The matcher, and the held-out check that decides which prints may guess
# (spec 2026-10-19 §7, §8).
class FieldVoiceprints::MatchingValidationTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  test "a guess needs the threshold and a margin over the runner-up" do
    prints = { 1 => voice_vector(1), 2 => voice_vector(2) }
    assert_equal [ 1 ], FieldVoiceprints::Matching.guesses({ a: voice_vector(1, noise: 0.1) }, prints)[:a].first(1)

    halfway = FieldVoiceprints.centroid([ voice_vector(1), voice_vector(2) ])
    assert_empty FieldVoiceprints::Matching.guesses({ a: halfway }, prints), "no margin, no guess"
    assert_empty FieldVoiceprints::Matching.guesses({ a: voice_vector(9) }, prints), "below threshold, no guess"
  end

  test "two speakers in one recording claiming one voice both stay unguessed unless both are very close" do
    prints = { 1 => voice_vector(1), 2 => voice_vector(2) }
    near = FieldVoiceprints.centroid([ voice_vector(1), voice_vector(9) ])
    assert_empty FieldVoiceprints::Matching.guesses({ a: voice_vector(1), b: near }, prints)
    assert_equal %i[a b], FieldVoiceprints::Matching.guesses({ a: voice_vector(1), b: voice_vector(1) }, prints).keys
  end

  # Six voices, each named in three recordings: every print is checked
  # against recordings it wasn't built from.
  def build_account(confuser: false)
    account = accounts(:personal_account)
    user = users(:user_1)
    voices = (1..6).map { |n| account.field_voices.create!(name: "Voice #{n}") }
    recordings = (1..3).map { long_ready_recording(account:, user:) }
    recordings.each_with_index do |recording, r|
      voices.each_with_index do |voice, v|
        holder = FieldRecordingSpeaker.create!(field_recording: recording, label: "v#{v}", position: 10 + v)
        vector = voice_vector(v, noise: 0.05, seed: (r * 10) + v)
        vector = voice_vector(0, noise: 0.05, seed: 99) if confuser && v == 5 && r == 2
        FieldVoiceSample.create!(account:, field_voice: voice, field_recording_speaker: holder, field_recording_id: recording.id,
          embedding: JSON.generate(vector), speech_ms: 5_000, profile: "ecapa-test", label_origin: "human", eligible: true)
      end
    end
    voices.each { |voice| voice.with_lock { FieldVoiceprints::Learning.rebuild!(voice) } }
    [ account, voices ]
  end

  test "well-separated voices with three recordings each are validated" do
    account, voices = build_account
    stats = FieldVoiceprints::Validation.run!(account)
    voices.each do |voice|
      print = voice.reload.voiceprint
      assert print.active?, "#{voice.name}: #{stats[voice.id]}"
      assert_equal 3, stats[voice.id]["queries"]
      assert_operator stats[voice.id]["negatives"], :>=, 10
    end
    assert_equal voices.size, FieldVoiceprints::Identification.active_prints(account).size
  end

  test "a print that another person's sample lands in is not validated" do
    account, voices = build_account(confuser: true)
    stats = FieldVoiceprints::Validation.run!(account)
    assert_operator stats[voices.first.id]["false_accepts_into"], :>, 0
    assert_not voices.first.reload.voiceprint.active?
  end

  test "a print from one recording is never validated, and a rebuilt print waits for the check again" do
    account, voices = build_account
    FieldVoiceSample.where(field_voice: voices.last).where.not(field_recording_id: FieldVoiceSample.where(field_voice: voices.last).minimum(:field_recording_id)).delete_all
    voices.last.with_lock { FieldVoiceprints::Learning.rebuild!(voices.last) }
    FieldVoiceprints::Validation.run!(account)
    assert_not voices.last.reload.voiceprint.active?
    assert voices.first.reload.voiceprint.active?

    voices.first.with_lock { FieldVoiceprints::Learning.rebuild!(voices.first) }
    assert_not voices.first.reload.voiceprint.active?, "validation is tied to the samples it was computed on"
  end

end
