require "test_helper"
require "action_cable/test_helper"
require "support/field_recording_helpers"

class FieldRecordingSpeakerBroadcastingTest < ActiveSupport::TestCase

  include ActionCable::TestHelper
  include FieldRecordingHelpers

  # Real commits, not the non-joinable fixture transaction's savepoints.
  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Speaker freshness #{SecureRandom.hex(4)}", account_type: "team")
    @user = users(:user_1)
    @recording = long_ready_recording(account: @account, user: @user)
    @speaker, @other = @recording.speakers.in_order.to_a
    @voice = @account.field_voices.create!(name: "Tomás")
  end

  teardown do
    @recording.audio.purge
    @account.destroy!
  end

  test "ignore and unignore invalidate detail and waiting counts after commit" do
    assert_equal 2, unnamed_count
    assert_refresh_after_commit { @speaker.ignore!(by: @user) }
    assert_equal 1, unnamed_count
    assert_refresh_after_commit { @speaker.unignore! }
    assert_equal 2, unnamed_count
  end

  test "reason-only ignore emits but same reason and already-unignored decisions are silent" do
    assert_silent { @speaker.unignore! }
    @speaker.ignore!(by: @user)
    generation = @speaker.decision_generation
    assert_refresh_after_commit { @speaker.ignore!(by: @user, as: "anonymous") }
    assert_equal generation, @speaker.reload.decision_generation
    assert_equal "anonymous", FieldItems.speaker_json(@speaker)[:ignored_as]
    assert_silent { @speaker.ignore!(by: @user, as: "anonymous") }
    @speaker.unignore!
    assert_silent { @speaker.unignore! }
  end

  test "suggestion dismissal emits once while stale and repeated dismissals are silent" do
    @speaker.update!(suggested_name: "Tomás", suggestion_quote: "Tomás speaking",
      suggestion_generation: @speaker.decision_generation)
    generation = @speaker.decision_generation

    assert_silent { assert_not @speaker.dismiss_suggestion!(generation + 1) }
    assert_refresh_after_commit { assert @speaker.dismiss_suggestion!(generation) }
    assert_nil FieldItems.speaker_json(@speaker.reload)[:suggestion]
    assert_silent { assert_not @speaker.dismiss_suggestion!(generation) }
  end

  test "recognition dismissal emits once while stale and repeated dismissals are silent" do
    @speaker.update!(recognised_voice: @voice, recognition_confidence: 85,
      recognition_print_generation: 0, recognition_decision_generation: @speaker.decision_generation)
    shown = @speaker.recognition_token

    assert_silent do
      assert_not @speaker.dismiss_recognition!(shown: shown.merge(decision_generation: -1))
    end
    assert_refresh_after_commit { assert @speaker.dismiss_recognition!(shown:) }
    assert_nil FieldItems.speaker_json(@speaker.reload)[:recognition]
    assert_silent { assert_not @speaker.dismiss_recognition!(shown:) }
  end

  test "naming and unname share existing parent writes even with an unchanged transcript" do
    # Linking a voice with the existing display name changes the chip, but not
    # the rendered transcript. Unname must still refresh the chip and count.
    @voice.update!(name: @speaker.default_name)
    original = @recording.reload.transcript_text
    assert_refresh_after_commit { @speaker.name_as!(@voice, by: @user) }
    assert_equal original, @recording.reload.transcript_text
    assert_equal 1, unnamed_count
    assert_refresh_after_commit { @speaker.unname! }
    assert_equal original, @recording.reload.transcript_text
    assert_equal 2, unnamed_count
  end

  test "a later speaker and recording touch do not lose or duplicate the marker" do
    assert_refresh_after_commit do
      @speaker.ignore!(by: @user)
      @speaker.touch
      @recording.touch
    end
  end

  test "separate instances and nested committed savepoints coalesce per recording" do
    assert_refresh_after_commit do
      @speaker.ignore!(by: @user)
      FieldRecordingSpeaker.transaction(requires_new: true) do
        FieldRecordingSpeaker.find(@other.id).ignore!(by: @user)
        FieldRecording.find(@recording.id).touch
      end
    end
    assert_equal 0, unnamed_count
  end

  test "outer rollback emits nothing and later reuse is not latched" do
    assert_silent do
      FieldRecording.transaction do
        @speaker.ignore!(by: @user)
        FieldRecording.transaction(requires_new: true) { @other.ignore!(by: @user) }
        raise ActiveRecord::Rollback
      end
    end
    assert_equal 2, unnamed_count
    @speaker.field_recording.reload
    assert_refresh_after_commit { @speaker.ignore!(by: @user) }
  end

  test "rolled back savepoint emits nothing and same instances work in a later transaction" do
    assert_silent do
      FieldRecording.transaction do
        FieldRecording.transaction(requires_new: true) do
          @speaker.ignore!(by: @user)
          @recording.touch
          raise ActiveRecord::Rollback
        end
      end
    end
    assert_equal 2, unnamed_count
    @speaker.field_recording.reload
    assert_refresh_after_commit { @speaker.ignore!(by: @user) }
  end

  test "a rolled back savepoint cannot discard an earlier valid marker" do
    assert_refresh_after_commit do
      @speaker.ignore!(by: @user)
      FieldRecording.transaction(requires_new: true) do
        @other.ignore!(by: @user)
        raise ActiveRecord::Rollback
      end
    end
    assert_equal 1, unnamed_count
  end

  test "a valid change after a rolled back savepoint still emits once" do
    assert_refresh_after_commit do
      FieldRecording.transaction(requires_new: true) do
        @speaker.ignore!(by: @user)
        raise ActiveRecord::Rollback
      end
      @other.ignore!(by: @user)
    end
    assert_equal 1, unnamed_count
  end

  test "suggestion success store keeps its existing parent touch without duplicate markers" do
    suggestions = [ @speaker, @other ].map do |speaker|
      { speaker:, name: "Tomás", quote: "Tomás speaking", at_ms: 0 }
    end
    snapshot = [ @speaker, @other ].to_h { |speaker| [ speaker.id, speaker.decision_generation ] }

    assert_refresh_after_commit do
      FieldRecordings::SuggestSpeakersJob.new.send(:store, @recording, suggestions, snapshot)
    end
    assert @speaker.reload.suggestion?
    assert @other.reload.suggestion?
  end

  test "multi-speaker recognition completion keeps its existing touch and emits once" do
    store_print!(@voice)
    identification = FieldRecordingIdentification.create!(field_recording: @recording,
      vendor_job_id: "freshness", snapshot: { "v1" => [ @voice.id, @voice.print_generation ] },
      speaker_decisions: [ @speaker, @other ].to_h { |speaker| [ speaker.id.to_s, speaker.decision_generation ] })
    output = {
      "identification" => [
        { "start" => 0.0, "end" => 12.0, "match" => "v1", "diarizationSpeaker" => "S" },
        { "start" => 14.0, "end" => 15.0, "match" => "v1", "diarizationSpeaker" => "T" },
        { "start" => 17.0, "end" => 22.0, "match" => "v1", "diarizationSpeaker" => "S" }
      ]
    }

    with_recognition(@account) do
      assert_refresh_after_commit { assert FieldVoiceprints::Identification.apply!(identification, output) }
    end
    assert_equal @voice.id, @speaker.reload.recognised_voice_id
    assert_equal @voice.id, @other.reload.recognised_voice_id
  end

  test "hidden suggestions state and non-rendered speaker bookkeeping stay silent" do
    assert_silent do
      %w[running done failed].each { |state| @recording.update_columns(suggestions_state: state) }
      @speaker.update!(decision_generation: @speaker.decision_generation + 1)
      @speaker.touch
    end
  end

  test "parent skip_broadcast suppresses both existing streams for speaker presentation saves" do
    @speaker.field_recording.skip_broadcast = true
    assert_silent { @speaker.update!(ignored_at: Time.current) }
    assert @speaker.reload.ignored?
  end

  test "ordinary naming keeps its existing transcript refresh and account target" do
    messages = capture_broadcasts("Account:#{@account.obfuscated_id}") do
      assert_refresh_after_commit { @speaker.name_as!(@voice, by: @user) }
    end
    assert_equal [ { "action" => "refresh" } ], messages
    assert_includes @recording.reload.transcript_text, "Tomás:"
  end

  test "an unchanged save and attribution-only changes are not presentation producers" do
    assert_silent do
      @speaker.save!
      @speaker.update!(ignored_by: @user, named_by: @user, named_at: Time.current,
        suggested_at: Time.current, suggestion_source: "not rendered")
    end
  end

  test "a recording touched before a rolled back speaker decision still refreshes once" do
    assert_refresh_after_commit do
      @recording.touch
      FieldRecording.transaction(requires_new: true) do
        @speaker.ignore!(by: @user)
        raise ActiveRecord::Rollback
      end
    end
    assert_equal 2, unnamed_count
  end

  test "each recording in one transaction gets one detail and one activity marker" do
    second = long_ready_recording(account: @account, user: @user)
    second_stream = "FieldRecording:#{second.obfuscated_id}"
    detail = other_detail = activity = nil
    detail = capture_broadcasts(detail_stream) do
      other_detail = capture_broadcasts(second_stream) do
        activity = capture_broadcasts(activity_stream) do
          FieldRecording.transaction do
            assert_silent do
              assert_no_broadcasts(second_stream) do
                @speaker.ignore!(by: @user)
                @other.ignore!(by: @user)
                second.speakers.each { |speaker| speaker.ignore!(by: @user) }
                second.touch
              end
            end
          end
        end
      end
    end
    marker = { "action" => "refresh", "prop" => "field_recording" }
    assert_equal [ marker ], detail
    assert_equal [ marker ], other_detail
    assert_equal [ { "action" => "refresh" } ] * 2, activity
  ensure
    second&.audio&.purge
  end

  test "speaker decision never emits another account marker" do
    assert_no_broadcasts("FieldActivity:#{accounts(:personal_account).obfuscated_id}") do
      assert_refresh_after_commit { @speaker.ignore!(by: @user) }
    end
  end

  private

  def unnamed_count
    FieldItems.recording_json(@recording.reload)[:unnamed_speakers]
  end

  def detail_stream = "FieldRecording:#{@recording.obfuscated_id}"
  def activity_stream = "FieldActivity:#{@account.obfuscated_id}"

  def assert_silent
    assert_no_broadcasts(detail_stream) do
      assert_no_broadcasts(activity_stream) { yield }
    end
  end

  def assert_refresh_after_commit
    activity = nil
    detail = capture_broadcasts(detail_stream) do
      activity = capture_broadcasts(activity_stream) do
        FieldRecording.transaction do
          assert_silent { yield }
        end
      end
    end
    assert_equal [ { "action" => "refresh", "prop" => "field_recording" } ], detail
    assert_equal [ { "action" => "refresh" } ], activity
  end

end
