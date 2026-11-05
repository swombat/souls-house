require "test_helper"

# A site speech-engine (or voice-mode) scope change must reach every open
# conversation, without opening the admin-only Setting:all stream to ordinary
# users (Mira's second review of #790, jEDyze).
class VoiceModeInvalidationJobTest < ActiveJob::TestCase

  include ActionCable::TestHelper

  setup do
    @setting = Setting.instance
    @setting.update!(speech_engine_scope: "disabled", voice_mode_scope: "disabled")
  end

  test "changing the speech engine scope enqueues the invalidation after commit" do
    assert_enqueued_with(job: VoiceModeInvalidationJob) do
      Setting.transaction do
        assert_no_enqueued_jobs(only: VoiceModeInvalidationJob) do
          @setting.update!(speech_engine_scope: "account_choice")
        end
      end
    end
  end

  test "changing the voice mode scope enqueues the invalidation" do
    assert_enqueued_with(job: VoiceModeInvalidationJob) do
      @setting.update!(voice_mode_scope: "enabled")
    end
  end

  test "other setting changes do not enqueue it" do
    assert_no_enqueued_jobs(only: VoiceModeInvalidationJob) do
      @setting.update!(site_name: "Renamed house")
    end
  end

  test "a rolled-back scope change enqueues nothing" do
    assert_no_enqueued_jobs(only: VoiceModeInvalidationJob) do
      Setting.transaction(requires_new: true) do
        @setting.update!(speech_engine_scope: "enabled")
        raise ActiveRecord::Rollback
      end
    end
  end

  test "sends one content-free voice_mode marker to each account stream and none to Setting:all" do
    accounts = Account.all.to_a
    assert accounts.size >= 2, "fixtures should give more than one account"

    assert_no_broadcasts("Setting:all") do
      VoiceModeInvalidationJob.perform_now
    end

    accounts.each do |account|
      stream = "Account:#{account.obfuscated_id}"
      payloads = broadcasts(stream).map { |raw| ActiveSupport::JSON.decode(raw) }
      assert_equal [ { "action" => "refresh", "prop" => "voice_mode" } ], payloads,
        "#{stream} should get exactly the content-free marker"
    end
  end

end
