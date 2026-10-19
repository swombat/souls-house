require "test_helper"
require "support/field_recording_helpers"

class FieldVoiceLifecycleActivityTest < ActiveSupport::TestCase

  include ActionCable::TestHelper
  include FieldRecordingHelpers

  self.use_transactional_tests = false

  setup do
    @user = users(:user_1)
    @accounts = 2.times.map do
      account = Account.create!(name: "Voice lifecycle #{SecureRandom.hex(4)}", account_type: :team)
      account.add_user!(@user, role: "owner", skip_confirmation: true)
      account
    end
    @account, @foreign = @accounts
    @recordings = 3.times.map { long_ready_recording(account: @account, user: @user) }
    @recording, @suggested, @recognised = @recordings
    @speaker = @recording.speakers.first
    @voice = @account.field_voices.create!(name: "SECRET-NAME")
    @speaker.name_as!(@voice, by: @user)
    clear_enqueued_jobs
  end

  teardown do
    @recordings.each { |recording| recording.audio.purge if FieldRecording.exists?(recording.id) }
    @accounts.each { |account| account.reload.destroy! if Account.exists?(account.id) }
  end

  # Speaker cards no longer show whether a voice is remembered, so a print
  # refreshes the Voices roster only, never a recording's detail.
  test "print creation metadata updates and destruction refresh the roster only" do
    print = nil
    assert_events(rosters: [ @account ]) { print = store_print!(@voice) }
    assert presentation[:remembered]
    { speech_ms: 20_000, sample_count: 3, recording_count: 3, validated: false, validated_digest: "other",
      generation: 4 }.each do |field, value|
      assert_events(rosters: [ @account ]) { print.update!(field => value) }
    end
    assert_events do
      print.update!(print: "SECRET-PRINT", profile: "ecapa-other", engine: "not rendered", validation: { "queries" => 1 })
      print.touch
    end
    assert_events(rosters: [ @account ]) { print.destroy! }
    assert_not presentation[:remembered]
  end

  test "print reassignment and stale account ownership use old and new voice owners" do
    foreign_voice = @foreign.field_voices.create!(name: "Foreign name")
    print = store_print!(@voice)
    assert_events(rosters: [ @account, @foreign ]) do
      print.update!(field_voice: foreign_voice)
    end
    assert_equal @account.id, print.account_id, "exercise deliberately stale print ownership"
    assert_events(rosters: [ @foreign ]) { FieldVoiceprint.find(print.id).destroy! }
  end

  test "forget captures recognised recordings before bulk clear and preserves names" do
    store_print!(@voice)
    recognise(@recognised)
    @recognised.update_columns(status: "queued")
    assert_events(details: [ @recognised ], rosters: [ @account ]) { @voice.forget! }
    assert_nil @recognised.speakers.first.reload.recognised_voice_id
    assert_equal @voice, @speaker.reload.field_voice
    assert_not presentation[:remembered]
  end

  test "deleting a name captures linked union suggested union recognised even without rerender changes" do
    @voice.update!(name: @speaker.default_name)
    @recording.update!(transcript_text: @recording.render_transcript_text)
    text = @recording.reload.transcript_text
    @suggested.speakers.first.update!(suggested_voice: @voice, suggested_name: "Suggestion", suggestion_generation: 0)
    recognise(@recognised)
    @recording.update_columns(status: "queued")
    @suggested.update_columns(status: "queued")
    assert_events(details: @recordings, rosters: [ @account ]) { @voice.delete_identity! }
    assert_equal text, @recording.reload.transcript_text
    assert_nil @speaker.reload.field_voice_id
    assert_nil @suggested.speakers.first.reload.suggested_voice_id
    assert_nil @recognised.speakers.first.reload.recognised_voice_id
  end

  test "forget all preserves per voice transactions and has an N voice bound" do
    second_voice = @account.field_voices.create!(name: "Second")
    @recording.speakers.last.name_as!(second_voice, by: @user)
    store_print!(@voice)
    store_print!(second_voice)
    unremembered = @account.field_voices.create!(name: "No print")
    # One transaction, and one roster hint, per voice: forgetting turns each
    # voice's learning off, which the roster shows, print or not.
    assert_events(rosters: [ @account, @account, @account ]) do
      FieldVoiceprints.forget_all!(@account)
    end
    assert_equal 1, unremembered.reload.print_generation
    assert_not unremembered.remember?
  end

  # Forget turns the voice's learning off (remember), which the roster shows,
  # so even a voice with no print refreshes the roster; linked names don't
  # make it touch their recordings.
  test "forgetting a voice with no print refreshes only the roster, even with linked names" do
    assert_events(rosters: [ @account ]) { @voice.forget! }
    assert_equal 1, @voice.reload.print_generation
    assert_not @voice.remember?
  end

  test "forget invalidations never write or lock recording rows under the voice lock" do
    store_print!(@voice)
    recognise(@recognised)
    queries = []
    observer = ->(*args) { queries << args.last[:sql] }
    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
      assert_events(details: [ @recognised ], rosters: [ @account ]) { @voice.forget! }
    end
    recording_writes = queries.grep(/(?:UPDATE|DELETE FROM|INSERT INTO) "field_recordings"|FROM "field_recordings".*FOR UPDATE/i)
    assert_empty recording_writes
  end

  test "bulk forget and delete rollbacks restore all state without leaking hints" do
    store_print!(@voice)
    recognise(@recognised)
    @suggested.speakers.first.update!(suggested_voice: @voice, suggested_name: "Suggestion")
    assert_events do
      FieldVoice.transaction do
        @voice.delete_identity!
        raise ActiveRecord::Rollback
      end
      FieldVoice.transaction do
        FieldVoice.transaction(requires_new: true) do
          @voice.reload.forget!
          raise ActiveRecord::Rollback
        end
      end
    end
    assert @voice.reload.remembered?
    assert @voice.kept?
    assert_equal @voice.id, @recognised.speakers.first.reload.recognised_voice_id
    assert_equal @voice.id, @suggested.speakers.first.reload.suggested_voice_id
    assert @voice.remember?
    assert_events(details: [ @recognised ], rosters: [ @account ]) { @voice.forget! }
  end

  test "print batches coalesce per account and recording and rollback never poisons later writes" do
    print = store_print!(@voice)
    assert_events(rosters: [ @account ]) do
      FieldVoiceprint.transaction do
        print.update!(speech_ms: 18_000)
        FieldVoiceprint.transaction(requires_new: true) do
          print.update!(speech_ms: 22_000)
          raise ActiveRecord::Rollback
        end
        FieldVoiceprint.find(print.id).update!(sample_count: 5)
        assert_events { print.reload.touch }
      end
    end
    assert_equal 18_000, print.reload.speech_ms
    assert_events do
      FieldVoiceprint.transaction do
        FieldVoiceprint.transaction(requires_new: true) { print.destroy! }
        raise ActiveRecord::Rollback
      end
    end
    assert_events(rosters: [ @account ]) { print.reload.destroy! }
  end

  test "operator restore is a refresh snapshot with no cross account live fanout" do
    store_print!(@voice)
    recognise(@recognised)
    assert_events { FieldVoiceprints.reset_all! }
    assert_not @voice.reload.remembered?
    assert_nil @recognised.speakers.first.reload.recognised_voice_id
  end

  test "committed savepoints defer hints to the outer commit with the established bounded count" do
    print = store_print!(@voice)
    assert_events(rosters: [ @account, @account ]) do
      FieldVoiceprint.transaction do
        assert_events do
          print.update!(speech_ms: 18_000)
          FieldVoiceprint.transaction(requires_new: true) { print.update!(speech_ms: 20_000) }
        end
      end
    end
  end

  test "delete keeps the existing changed transcript broadcast as well as its explicit bulk hint" do
    assert_events(details: [ @recording, @recording ], rosters: [ @account ]) { @voice.delete_identity! }
    assert_match "Speaker 1:", @recording.reload.transcript_text
  end

  test "a refresh does not cut, embed, identify or enqueue work" do
    FieldVoiceprints::VoiceEmbeddings.stub(:embed, ->(*) { flunk "no embedding from presentation" }) do
      FieldVoiceprints::Sample.stub(:cut, ->(*) { flunk "no sample work from presentation" }) do
        assert_no_enqueued_jobs do
          assert_events(rosters: [ @account ]) { FieldVoiceActivity.refresh!([ @account.id ]) }
          assert_events(details: [ @recording ]) { FieldRecordingActivity.refresh!([ @recording.id ]) }
        end
      end
    end
  end

  private

  def recognise(recording)
    recording.speakers.first.update!(recognised_voice: @voice, recognition_confidence: 90,
      recognition_print_generation: @voice.reload.print_generation, recognition_decision_generation: 0)
  end

  def presentation
    FieldItems.voice_page_json(FieldVoice.find(@voice.id), 0)
  end

  def assert_events(details: [], rosters: [])
    expected = details.map { |recording| [ "FieldRecording:#{recording.to_param}", { action: "refresh", prop: "field_recording" } ] } +
      rosters.map { |account| [ "FieldVoiceActivity:#{account.to_param}", { action: "refresh" } ] }
    events = []
    subscriber = ->(*args) do
      payload = args.last
      if payload[:broadcasting].start_with?("FieldRecording:", "FieldVoiceActivity:")
        events << [ payload[:broadcasting], payload[:message] ]
      end
    end
    ActiveSupport::Notifications.subscribed(subscriber, "broadcast.action_cable") { yield }
    assert_equal expected.sort_by(&:first), events.sort_by(&:first)
  end

end
