require "test_helper"
require "support/field_recording_helpers"

class FieldVoiceActivityTest < ActiveSupport::TestCase

  include ActionCable::TestHelper
  include FieldRecordingHelpers

  self.use_transactional_tests = false

  setup do
    @user = users(:user_1)
    @account, @other = 2.times.map do |i|
      account = Account.create!(name: "Voice roster #{i} #{SecureRandom.hex(4)}", account_type: :team)
      account.add_user!(@user, role: "owner", skip_confirmation: true)
      account
    end
    @member = User.create!(email_address: "voice-roster-#{SecureRandom.hex(6)}@example.test")
    @member.personal_account.destroy!
    @account.add_user!(@member, skip_confirmation: true)
    @member.profile.update!(first_name: "Roster", last_name: "Member")
    @recording = long_ready_recording(account: @account, user: @user)
    @speaker, @second = @recording.speakers.in_order.to_a
    @voice = @account.field_voices.create!(name: "Synthetic voice")
    clear_enqueued_jobs
  end

  teardown do
    @recording.audio.purge if FieldRecording.exists?(@recording.id)
    [ @account, @other ].each { |account| account.reload.destroy! if Account.exists?(account.id) }
    @member.reload.destroy! if User.exists?(@member.id)
  end

  test "voice create rename member link and discard emit content-free account hints" do
    voice = nil
    assert_refreshes(@account) { voice = @account.field_voices.create!(name: "SECRET-NAME-SENTINEL") }
    assert_refreshes(@account) { voice.update!(name: "SECRET-RENAMED-SENTINEL") }
    assert_refreshes(@account) { voice.update!(user: @member) }
    assert FieldItems.voices_json(@account).find { |row| row[:id] == voice.to_param }[:member]
    assert_refreshes(@account) { voice.discard! }
    assert_not_includes FieldItems.voices_json(@account).map { |row| row[:id] }, voice.to_param
    assert_silent { assert_not voice.discard }
    assert_refreshes(@account) { voice.undiscard! }
    assert_silent { assert_not voice.undiscard }
  end

  test "voice account reassignment and destruction capture ownership" do
    assert_refreshes(@account, @other) { @voice.update!(account: @other) }
    assert_refreshes(@other) { @voice.destroy! }
  end

  test "rendered changes wait for the outer commit and survive touch and reload" do
    assert_refreshes(@account) do
      FieldVoice.transaction do
        assert_silent do
          @voice.update!(name: "Committed name")
          @voice.touch
          @voice.save!
          @voice.reload
        end
      end
    end
  end

  test "outer and savepoint rollbacks are silent and do not latch later writes" do
    assert_silent do
      FieldVoice.transaction do
        @voice.update!(name: "Rolled back")
        @account.update!(recognise_voices: true)
        raise ActiveRecord::Rollback
      end
    end
    assert_silent do
      FieldVoice.transaction do
        FieldVoice.transaction(requires_new: true) do
          @voice.reload.discard!
          raise ActiveRecord::Rollback
        end
      end
    end
    assert_refreshes(@account) do
      FieldVoice.transaction do
        FieldVoice.transaction(requires_new: true) do
          @voice.reload.update!(name: "Savepoint rollback")
          raise ActiveRecord::Rollback
        end
        @voice.reload.update!(name: "Later commit")
      end
    end
  end

  test "rolled back create and destruction stay silent" do
    assert_silent do
      FieldVoice.transaction do
        @account.field_voices.create!(name: "Rolled back creation")
        @voice.destroy!
        raise ActiveRecord::Rollback
      end
    end
    assert FieldVoice.exists?(@voice.id)
  end

  test "helper deduplicates recipients and skips missing or deleted accounts" do
    assert_refreshes(@account) { FieldVoiceActivity.refresh!([ @account.id, @account.id, nil, -1 ]) }
    @other.destroy!
    assert_silent { FieldVoiceActivity.refresh!([ @other.id ]) }
  end

  # Recognition is on by default now, so the switch is exercised off, then on.
  test "recognition switch refreshes roster without emitting guest or recording hints" do
    assert @account.recognise_voices?, "on by default"
    assert_no_broadcasts("GuestDirectory:#{@account.to_param}") do
      assert_no_broadcasts(detail_stream) do
        assert_refreshes(@account) { @account.with_lock { @account.update!(recognise_voices: false) } }
      end
    end
    assert_refreshes(@account) { @account.update!(recognise_voices: true) }
    assert_silent { @account.update!(recognise_voices: true) }
  end

  test "membership role confirmation reassignment and removal refresh permission and member options" do
    membership = @account.memberships.find_by!(user: @member)
    assert @account.manageable_by?(@member), "the existing policy trusts every confirmed member"
    assert_refreshes(@account) { membership.update!(role: "admin") }
    assert @account.manageable_by?(@member)
    assert_refreshes(@account) { membership.update!(confirmed_at: nil) }
    assert_not @account.manageable_by?(@member)
    assert_refreshes(@account, @other) { membership.update!(account: @other) }
    assert_not_includes member_ids(@account), @member.id
    assert_includes member_ids(@other), @member.id
    assert_refreshes(@other) { membership.reload.destroy! }
    assert_not_includes member_ids(@other), @member.id
  end

  test "pending membership create and removal follow the existing all-members presenter" do
    @account.memberships.find_by!(user: @member).destroy!
    membership = nil
    assert_refreshes(@account) { membership = @account.add_user!(@member) }
    assert_not membership.confirmed?
    assert_includes member_ids(@account), @member.id
    assert_refreshes(@account) { membership.destroy! }
    assert_not_includes member_ids(@account), @member.id
  end

  test "member profile and email labels refresh without touching recording content" do
    assert_no_broadcasts(detail_stream) do
      assert_refreshes(@account) { @member.profile.update!(first_name: "Renamed") }
      assert_equal "Renamed Member", FieldItems.members_without_voice_json(@account).find { |row| row[:user_id] == @member.id }[:name]
      assert_refreshes(@account) { @member.update!(email_address: "voice-renamed-#{SecureRandom.hex(4)}@example.test") }
      assert_refreshes(@account) { @member.profile.destroy! }
      assert_match "voice-renamed-", FieldItems.members_without_voice_json(@account).find { |row| row[:user_id] == @member.id }[:name]
    end
  end

  test "member presentation rollback at the outer and savepoint boundaries stays silent" do
    assert_silent do
      Profile.transaction do
        @member.profile.update!(first_name: "Rolled back")
        @member.update!(email_address: "voice-rollback-#{SecureRandom.hex(4)}@example.test")
        @account.memberships.find_by!(user: @member).destroy!
        raise ActiveRecord::Rollback
      end
    end
    assert_silent do
      Membership.transaction do
        Membership.transaction(requires_new: true) do
          @account.memberships.find_by!(user: @member).update!(confirmed_at: nil)
          @member.profile.reload.update!(last_name: "Savepoint")
          raise ActiveRecord::Rollback
        end
      end
    end
    assert_refreshes(@account) { @member.profile.reload.update!(last_name: "Committed") }
  end

  test "user destruction snapshots memberships and database-nullified voice links first" do
    @voice.update!(user: @member)
    remote_voice = @other.field_voices.create!(name: "Remote linked member", user: @member)
    observed = nil
    @member.define_singleton_method(:snapshot_voice_roster_accounts) do
      observed = [ memberships.ids, FieldVoice.where(user_id: id).ids ]
      super()
    end
    assert_refreshes(@account, @other) { @member.destroy! }
    assert_not_empty observed.first
    assert_equal [ @voice.id, remote_voice.id ].sort, observed.last.sort
    assert_nil @voice.reload.user_id
    assert_nil remote_voice.reload.user_id
    assert_not FieldItems.voices_json(@account).find { |row| row[:id] == @voice.to_param }[:member]
    assert_not_includes member_ids(@account), @member.id
  end

  test "aborted user and account destruction emit no roster marker" do
    # The account's last owner deliberately cannot be removed via User.
    @account.memberships.find_by!(user: @member).update!(role: "owner")
    @account.memberships.find_by!(user: @user).update!(role: "member")
    assert_silent { assert_not @member.destroy }
    agent = @account.agents.create!(name: "Restricted synthetic", runtime: "external", model_id: "openrouter/auto")
    vault = agent.create_memory_vault!
    assert_silent { assert_not @account.destroy }
  ensure
    vault&.destroy!
  end

  test "user deletion rollback restores member and linked voice without any hint" do
    @voice.update!(user: @member)
    assert_silent do
      User.transaction do
        @member.destroy!
        raise ActiveRecord::Rollback
      end
    end
    assert User.exists?(@member.id)
    assert_equal @member.id, @voice.reload.user_id
    assert_refreshes(@account) { User.find(@member.id).destroy! }
  end

  test "naming and un-naming update actual roster usage even when transcript text is unchanged" do
    @voice.update!(name: @speaker.default_name)
    text = @recording.reload.transcript_text
    assert_refreshes(@account) { @speaker.name_as!(@voice, by: @user) }
    assert_equal text, @recording.reload.transcript_text
    assert_equal 1, used_count(@voice)
    assert_refreshes(@account) { @speaker.unname! }
    assert_equal text, @recording.reload.transcript_text
    assert_equal 0, used_count(@voice)
  end

  test "relinking captures old and new voice ownership without broadening naming permissions" do
    remote = @other.field_voices.create!(name: "Remote voice")
    @speaker.name_as!(@voice, by: @user)
    assert_silent { assert_raises(ArgumentError) { @speaker.name_as!(remote, by: @user) } }
    # Exercise the model callback with distinct owners, independently of the
    # endpoint's unchanged same-account guard.
    assert_refreshes(@account, @other) { @speaker.update!(field_voice: remote) }
    assert_equal 0, used_count(@voice)
    assert_equal 1, used_count(remote)
    assert_refreshes(@other) { @speaker.update!(field_voice: nil) }
  end

  test "linked named-at changes refresh picker order without touching transcript detail" do
    other_voice = @account.field_voices.create!(name: "Older name")
    @speaker.update!(field_voice: @voice, named_at: 2.days.ago)
    @second.update!(field_voice: other_voice, named_at: 1.day.ago)
    assert_equal other_voice.to_param, FieldItems.voices_json(@account).first[:id]
    assert_no_broadcasts(detail_stream) do
      assert_refreshes(@account) { @speaker.update!(named_at: Time.current) }
    end
    assert_equal @voice.to_param, FieldItems.voices_json(@account).first[:id]
  end

  test "linked speaker creation and destruction refresh raw roster counts" do
    speaker = nil
    assert_refreshes(@account) do
      speaker = @recording.speakers.create!(label: "speaker_new", position: 2, field_voice: @voice)
    end
    assert_equal 1, used_count(@voice)
    assert_refreshes(@account) { speaker.destroy! }
    assert_equal 0, used_count(@voice)
  end

  test "recording destruction follows the actual dependent speaker count changes" do
    @speaker.name_as!(@voice, by: @user)
    @second.name_as!(@voice, by: @user)
    blob = @recording.audio.blob
    assert_equal 2, used_count(@voice)
    assert_equal [ roster_stream(@account) ], roster_events { @recording.destroy! }
    assert_equal 0, used_count(@voice)
  ensure
    blob&.purge
  end

  test "destroying the account does not signal deleted or unrelated account rosters" do
    @speaker.name_as!(@voice, by: @user)
    @recording.audio.purge
    assert_silent { @account.destroy! }
    assert Account.exists?(@other.id)
  end

  test "speaker naming rollback and rolled back savepoints stay silent" do
    assert_silent do
      FieldRecordingSpeaker.transaction do
        @speaker.name_as!(@voice, by: @user)
        raise ActiveRecord::Rollback
      end
    end
    assert_silent do
      FieldRecordingSpeaker.transaction do
        FieldRecordingSpeaker.transaction(requires_new: true) do
          @speaker.reload.name_as!(@voice, by: @user)
          raise ActiveRecord::Rollback
        end
      end
    end
    assert_equal 0, used_count(@voice)
    assert_refreshes(@account) { @speaker.reload.name_as!(@voice, by: @user) }
  end

  test "batches coalesce roster hints per account and keep one existing detail hint" do
    markers = capture_broadcasts(detail_stream) do
      assert_equal [ roster_stream(@account) ], roster_events {
        FieldRecording.transaction do
          assert_silent do
            @speaker.name_as!(@voice, by: @user)
            @second.name_as!(@voice, by: @user)
            @speaker.touch
            @recording.touch
          end
        end
      }
    end
    assert_equal [ { "action" => "refresh", "prop" => "field_recording" } ], markers
    assert_equal 2, used_count(@voice)
  end

  test "suggested voice id alone changes neither eligibility nor rendered suggestion" do
    empty = FieldItems.speaker_json(@speaker)
    assert_no_broadcasts(detail_stream) do
      assert_silent { @speaker.update!(suggested_voice: @voice) }
    end
    assert_not @speaker.reload.suggestion?
    assert_equal empty, FieldItems.speaker_json(@speaker)
    @speaker.update!(suggested_name: "Suggested", suggestion_quote: "Suggested speaking", suggestion_generation: 0)
    before = FieldItems.speaker_json(@speaker.reload)
    assert @speaker.suggestion?
    assert_no_broadcasts(detail_stream) do
      assert_silent { @speaker.update!(suggested_voice: nil) }
    end
    assert @speaker.reload.suggestion?
    assert_equal before, FieldItems.speaker_json(@speaker)
    assert_silent { @speaker.update!(suggested_voice: @voice) }
    assert @speaker.reload.suggestion?
  end

  test "hidden voice bookkeeping ordinary speaker activity and unrelated traffic stay silent" do
    assert_silent do
      @voice.update!(print_generation: @voice.print_generation + 1, created_by: @user)
      @voice.touch
      @voice.save!
      @speaker.update!(suggested_name: "Suggestion", suggestion_quote: "A quote", suggestion_generation: 0)
      @speaker.update!(decision_generation: 1, named_at: Time.current, named_by: @user, ignored_by: @user,
        suggestion_source: "not rendered", suggested_at: Time.current)
      @speaker.update!(ignored_at: Time.current, ignored_as: "anonymous")
      @recording.update!(notes: "Unfinished meeting notes")
      @recording.touch
      @recording.update_columns(suggestions_state: "done")
      @account.update!(name: "Other account setting", logo_colour: "moss")
      @member.profile.update!(theme: "dark", timezone: "UTC")
      @member.update!(default_account_id: @account.id)
      chat = @account.chats.create!(title: "Ordinary", model_id: "openrouter/auto", manual_responses: true,
        agents: [ @account.agents.create!(name: "Quiet synthetic", runtime: "offline", model_id: "openrouter/auto") ])
      chat.messages.create!(role: "user", content: "Ordinary message")
      chat.agents.first.update!(health_state: "unhealthy", last_health_check_at: Time.current)
      IntegrationStatus.refresh!([ @account.id ])
      GuestDirectory.refresh!([ @account.id ])
    end
  end

  # Forget turns the voice's learning off, which the roster shows, so it is
  # one roster hint even with no print; invalid or unchanged writes stay silent.
  test "forget is one roster hint; invalid or unchanged writes stay silent in A" do
    assert_refreshes(@account) { @voice.forget! }
    assert_silent do
      assert_not @voice.update(name: "")
      @voice.reload.update!(name: @voice.name)
      @voice.touch
    end
  end

  test "the marker helper only broadcasts and invokes no work" do
    assert_no_enqueued_jobs do
      FieldVoiceprints.stub(:enabled_for?, ->(*) { flunk "refresh must not invoke recognition" }) do
        assert_refreshes(@account) { FieldVoiceActivity.refresh!([ @account.id ]) }
      end
    end
  end

  private

  def member_ids(account)
    FieldItems.members_without_voice_json(account).map { |row| row[:user_id] }
  end

  def used_count(voice)
    FieldItems.voice_page_json(voice.reload, FieldRecordingSpeaker.where(field_voice_id: voice.id).count)[:used_in]
  end

  def detail_stream = "FieldRecording:#{@recording.to_param}"
  def roster_stream(account) = "FieldVoiceActivity:#{account.to_param}"

  def roster_events
    events = []
    subscriber = ->(*args) do
      payload = args.last
      if payload[:broadcasting].start_with?("FieldVoiceActivity:")
        assert_equal({ action: "refresh" }, payload[:message])
        events << payload[:broadcasting]
      end
    end
    ActiveSupport::Notifications.subscribed(subscriber, "broadcast.action_cable") { yield }
    events
  end

  def assert_refreshes(*accounts, &block)
    assert_equal accounts.map { |account| roster_stream(account) }.sort, roster_events(&block).sort
  end

  def assert_silent(&block)
    assert_empty roster_events(&block)
  end

end
