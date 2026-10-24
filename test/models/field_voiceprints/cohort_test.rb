require "test_helper"
require "support/field_recording_helpers"

# The cohort is read on every sample list and voices page. Its confirmation
# checks load their sources in a fixed number of queries, however many
# voices and samples the account has, and agree with the per-sample checks.
class FieldVoiceprints::CohortTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
  end

  def cohort_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    result = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { FieldVoiceprints::Cohort.active(@account) }
    [ result, count ]
  end

  def add_voices(count)
    count.times.map do |index|
      voice = @account.field_voices.create!(name: "Synthetic #{SecureRandom.hex(3)} #{index}")
      store_print!(voice)
      voice
    end
  end

  test "the cohort reads its sources in a fixed number of queries" do
    add_voices(2)
    recording = long_ready_recording(account: @account, user: @user)
    backed = @account.field_voices.create!(name: "Recording-backed")
    2.times { confirmed_recording_sample!(backed, recording:, vector: voice_vector(7)) }
    FieldVoiceprints::Learning.rebuild!(backed.reload)
    restamp_cohort!(@account)
    (small, few) = cohort_queries

    add_voices(4)
    (large, many) = cohort_queries

    assert_operator large.first.size, :>, small.first.size
    assert_equal few, many, "cohort queries grew with the number of voices"
  end

  test "preloaded confirmation agrees with the per-sample check" do
    add_voices(2)
    recording = long_ready_recording(account: @account, user: @user)
    backed = @account.field_voices.create!(name: "Recording-backed")
    confirmed = confirmed_recording_sample!(backed, recording:, vector: voice_vector(7))
    unconfirmed = confirmed_recording_sample!(backed, recording:, vector: voice_vector(8))
    unconfirmed.field_recording_speaker.update_columns(sample_confirmed_digest: "stale")
    discarded = @account.field_voices.create!(name: "Discarded source")
    store_print!(discarded)
    discarded.samples.first.update_columns(field_recording_id: recording.id)

    rows = FieldVoiceSample.with_confirmation_sources.where(account: @account).to_a
    assert_operator rows.size, :>=, 8
    rows.each do |row|
      assert_equal FieldVoiceSample.find(row.id).manually_confirmed?, row.preloaded_manually_confirmed?, "sample #{row.id}"
    end
    assert rows.find { |row| row.id == confirmed.id }.preloaded_manually_confirmed?
    assert_not rows.find { |row| row.id == unconfirmed.id }.preloaded_manually_confirmed?

    # A source recording discarded later stops counting, preloaded or not.
    recording.discard!
    rows = FieldVoiceSample.with_confirmation_sources.where(account: @account).to_a
    rows.each do |row|
      assert_equal FieldVoiceSample.find(row.id).manually_confirmed?, row.preloaded_manually_confirmed?, "sample #{row.id} after discard"
    end
  end

end
