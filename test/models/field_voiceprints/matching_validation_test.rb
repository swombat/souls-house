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

  def unit(**axes)
    vector = Array.new(192, 0.0)
    axes.each { |axis, value| vector[axis.to_s.delete("e").to_i] = value }
    norm = Math.sqrt(vector.sum { |value| value * value })
    vector.map { |value| value / norm }
  end

  def add_sample(account, voice, recording, vector)
    assert_equal account.id, voice.account_id
    confirmed_recording_sample!(voice, recording:, vector:)
  end

  def rebuild_all(voices)
    voices.each { |voice| voice.with_lock { FieldVoiceprints::Learning.rebuild!(voice) } }
  end

  def active_voice_ids(account) = FieldVoiceprints::Identification.active_prints(account).map(&:field_voice_id)

  # n orthogonal voices (axes 1..n), each named in three recordings.
  def orthogonal_account(n)
    account = accounts(:personal_account)
    user = users(:user_1)
    voices = (1..n).map { |axis| account.field_voices.create!(name: "Axis #{axis}") }
    recordings = (1..3).map { long_ready_recording(account:, user:) }
    voices.each_with_index { |voice, i| recordings.each { |recording| add_sample(account, voice, recording, unit("e#{i + 1}": 1.0)) } }
    [ account, voices, user ]
  end

  # Mira's finding 1 (Carl's fixture): a single-recording voice's query is
  # wrongly accepted into voice 1. Its own voice has no held-out print, but
  # the false accept still counts against voice 1.
  test "a wrong accept counts even when the query's own voice has no held-out print" do
    account, voices, user = orthogonal_account(6)
    seventh = account.field_voices.create!(name: "Seventh")
    recording = long_ready_recording(account:, user:)
    add_sample(account, seventh, recording, unit(e1: 0.6, e9: 0.8))
    # Two confirmations make a print, but neither has an own held-out print.
    # Keep this second query below threshold so it does not invoke the
    # production matcher's same-recording double-claim suppression.
    add_sample(account, seventh, recording, unit(e1: 0.1, e9: Math.sqrt(0.99)))
    rebuild_all(voices + [ seventh ])

    stats = FieldVoiceprints::Validation.run!(account)
    assert_equal 1, stats[voices.first.id]["false_accepts_into"]
    assert_not_includes active_voice_ids(account), voices.first.id
    assert_includes active_voice_ids(account), voices.second.id
  end

  # Mira's finding 2 (Carl's fixture): a print that fails can't stay in as a
  # competitor that absorbs a wrong match the active set would make.
  test "validation measures against the prints that will actually be active" do
    account, voices, user = orthogonal_account(6)
    add_sample(account, voices.second, long_ready_recording(account:, user:), unit(e1: 0.6, e9: 0.8))
    seventh = account.field_voices.create!(name: "Seventh")
    recording = long_ready_recording(account:, user:)
    add_sample(account, seventh, recording, unit(e1: 0.5, e9: Math.sqrt(0.75)))
    add_sample(account, seventh, recording, unit(e1: 0.1, e9: Math.sqrt(0.99)))
    rebuild_all(voices + [ seventh ])

    FieldVoiceprints::Validation.run!(account)
    active = active_voice_ids(account)
    assert_not_includes active, seventh.id
    assert_not_includes active, voices.second.id
    assert_not_includes active, voices.first.id, "against the real active set, voice 2's stray query lands in voice 1"
    assert_equal voices[2..].map(&:id).sort, active.sort
  end

  # Mira's finding 3: a verdict belongs to the cohort it was measured in.
  test "forgetting one voice retires every verdict until the check runs again" do
    account, voices, = orthogonal_account(5)
    rebuild_all(voices)
    stats = FieldVoiceprints::Validation.run!(account)
    assert_equal 12, stats[voices.first.id]["negatives"]
    assert_includes active_voice_ids(account), voices.first.id

    voices.last.forget!
    assert_empty active_voice_ids(account), "the cohort changed, so no verdict stands"
    stats = FieldVoiceprints::Validation.run!(account)
    assert_equal 9, stats[voices.first.id]["negatives"]
    assert_empty active_voice_ids(account), "nine negatives are not enough"
  end

  test "a verdict isn't published if the cohort changes while it is measured" do
    account, voices, = orthogonal_account(6)
    rebuild_all(voices)
    measure = FieldVoiceprints::Validation.method(:measure)
    FieldVoiceprints::Validation.stub(:measure, ->(*args) {
      result = measure.call(*args)
      voices.last.with_lock { FieldVoiceprints::Learning.rebuild!(voices.last) }
      result
    }) do
      assert_nil FieldVoiceprints::Validation.run!(account)
    end
    assert_empty active_voice_ids(account)
    assert FieldVoiceprint.where(account:).none?(&:validated)
  end

  # Mira's second review, finding 2: the profile comes from the samples, so
  # publishing verdicts can't change which profile the next check uses.
  test "validating twice in a mixed-profile account gives the same verdicts" do
    account = accounts(:personal_account)
    user = users(:user_1)
    old_voices = (1..6).map { |axis| account.field_voices.create!(name: "Old #{axis}") }
    recordings = (1..3).map { long_ready_recording(account:, user:) }
    old_voices.each_with_index do |voice, i|
      recordings.each do |recording|
        add_sample(account, voice, recording, unit("e#{i + 1}": 1.0)).update_columns(profile: "ecapa-old")
      end
    end
    rebuild_all(old_voices)
    current_voices = (1..6).map { |axis| account.field_voices.create!(name: "Current #{axis}") }
    current_voices.each_with_index { |voice, i| recordings.each { |recording| add_sample(account, voice, recording, unit("e#{i + 20}": 1.0)) } }
    rebuild_all(current_voices)

    FieldVoiceprints::Validation.run!(account)
    first = active_voice_ids(account).sort
    FieldVoiceprints::Validation.run!(account)
    assert_equal first, active_voice_ids(account).sort
    assert_empty first, "eligible confirmed samples outside the active recipe pause matching until conversion or removal"
    assert_equal FieldVoiceprints::Profiles::ECAPA, FieldVoiceprints::Cohort.profile(account)
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
        vector = voice_vector(v, noise: 0.05, seed: (r * 10) + v)
        vector = voice_vector(0, noise: 0.05, seed: 99) if confuser && v == 5 && r == 2
        add_sample(account, voice, recording, vector)
      end
    end
    voices.each { |voice| voice.with_lock { FieldVoiceprints::Learning.rebuild!(voice) } }
    [ account, voices ]
  end

  test "well-separated voices with three recordings each are validated" do
    account, voices = build_account
    stats = FieldVoiceprints::Validation.run!(account)
    voices.each do |voice|
      assert_includes active_voice_ids(account), voice.id, "#{voice.name}: #{stats[voice.id]}"
      assert_equal 3, stats[voice.id]["queries"]
      assert_operator stats[voice.id]["negatives"], :>=, 10
    end
  end

  test "a print that another person's sample lands in is not validated" do
    account, voices = build_account(confuser: true)
    stats = FieldVoiceprints::Validation.run!(account)
    assert_operator stats[voices.first.id]["false_accepts_into"], :>, 0
    assert_not_includes active_voice_ids(account), voices.first.id
  end

  test "a print from one recording is never validated, and a rebuilt print waits for the check again" do
    account, voices = build_account
    FieldVoiceSample.where(field_voice: voices.last).where.not(field_recording_id: FieldVoiceSample.where(field_voice: voices.last).minimum(:field_recording_id)).delete_all
    voices.last.with_lock { FieldVoiceprints::Learning.rebuild!(voices.last) }
    assert_nil voices.last.reload.voiceprint, "one confirmed sample cannot form a print"
    FieldVoiceprints::Validation.run!(account)
    assert_not_includes active_voice_ids(account), voices.last.id
    assert_includes active_voice_ids(account), voices.first.id

    voices.first.with_lock { FieldVoiceprints::Learning.rebuild!(voices.first) }
    assert_empty active_voice_ids(account), "validation is tied to the samples it was computed on"
  end

end
