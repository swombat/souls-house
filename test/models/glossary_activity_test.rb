require "test_helper"

class GlossaryActivityTest < ActiveSupport::TestCase

  include ActionCable::TestHelper
  self.use_transactional_tests = false

  setup do
    @home = Account.create!(name: "Glossary #{SecureRandom.hex(4)}", account_type: :team)
    @other = Account.create!(name: "Glossary other #{SecureRandom.hex(4)}", account_type: :team)
    @glossary = TranscriptionGlossary.new(@home)
    @user = users(:user_1)
    @setting = Setting.instance
    @site_name = @setting.site_name
    @max_accounts = @setting.max_accounts
    clear_enqueued_jobs
  end

  teardown do
    @setting.update!(site_name: @site_name) if @setting.reload.site_name != @site_name
    @setting.update!(max_accounts: @max_accounts) if @setting.max_accounts != @max_accounts
    [ @home, @other ].each { |account| account.reload.destroy! }
  end

  test "stored add pin unpin suppression restore and actual deletion emit content free home markers" do
    record = nil
    assert_no_broadcasts(stream(@other)) do
      marker(@home) { record = @glossary.add!("Private vocabulary", by: @user) }
      marker(@home) { record.update!(pinned: true) }
      marker(@home) { record.update!(pinned: false) }
      marker(@home) { @glossary.remove!(record.term, by: @user) }
      marker(@home) { record = @glossary.add!(record.term, by: @user) }
      marker(@home) { record.destroy! }
    end
  end

  test "future direct writers and moves capture old and new accounts before later saves and deletion" do
    record = nil
    marker(@home) { record = @home.transcription_glossary_terms.create!(term: "Learned", source: "harvested") }
    marker(@home) do
      marker(@other, count: 2) do
        TranscriptionGlossaryTerm.transaction do
          record.update!(account: @other)
          record.touch
          record.destroy!
        end
      end
    end
  end

  test "rollback savepoint invalid writes touch and unrelated settings stay quiet" do
    record = @glossary.add!("Kept", by: @user)
    assert_no_broadcasts(stream(@home)) do
      TranscriptionGlossaryTerm.transaction do
        record.update!(pinned: true)
        raise ActiveRecord::Rollback
      end
      record.reload
      TranscriptionGlossaryTerm.transaction do
        TranscriptionGlossaryTerm.transaction(requires_new: true) do
          record.destroy!
          raise ActiveRecord::Rollback
        end
      end
      record = TranscriptionGlossaryTerm.find(record.id)
      record.touch
      assert_raises(ActiveRecord::RecordInvalid) { @glossary.add!("bad <word>", by: @user) }
      @setting.touch
    end
    assert_no_enqueued_jobs(only: RefreshGlossarySettingsJob) do
      @setting.update!(site_name: @site_name, max_accounts: @max_accounts + 1)
    end
    marker(@home) do
      TranscriptionGlossaryTerm.transaction do
        assert_no_broadcasts(stream(@home)) { record.update!(pinned: true); record.touch }
      end
    end
  end

  test "site name enqueues only after commit and fans out in batches to enabled accounts" do
    assert_no_enqueued_jobs(only: RefreshGlossarySettingsJob) do
      Setting.transaction do
        @setting.update!(site_name: "Rolled back house")
        raise ActiveRecord::Rollback
      end
      @setting.reload
      Setting.transaction do
        Setting.transaction(requires_new: true) do
          @setting.update!(site_name: "Rolled back savepoint")
          raise ActiveRecord::Rollback
        end
      end
    end
    @setting.reload
    assert_enqueued_with(job: RefreshGlossarySettingsJob) do
      Setting.transaction do
        assert_no_enqueued_jobs(only: RefreshGlossarySettingsJob) { @setting.update!(site_name: "Renamed house") }
      end
    end
    @other.update!(disabled_at: Time.current)
    assert_no_broadcasts(stream(@other)) do
      marker(@home) { RefreshGlossarySettingsJob.perform_now }
    end
    assert_includes @glossary.keyterms, "Renamed house"
  end

  private

  def stream(account)
    "GlossaryActivity:#{account.to_param}"
  end

  def marker(account, count: 1)
    assert_equal Array.new(count) { { "action" => "refresh" } }, capture_broadcasts(stream(account)) { yield }
  end

end
