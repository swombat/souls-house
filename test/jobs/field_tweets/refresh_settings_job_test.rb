require "test_helper"

class FieldTweets::RefreshSettingsJobTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @setting = Setting.instance
    @original = @setting.attributes.except("id", "created_at", "updated_at")
    @setting.update_columns(allow_agents: true, field_tweets_enabled: false,
      field_tweets_daily_import_cap: 50, field_tweets_poll_minutes: 15,
      field_tweets_account_monthly_usd_ceiling: 1, field_tweets_site_monthly_usd_ceiling: 10,
      field_tweets_house_halted_at: nil)
    @account = Account.create!(name: "Settings discovery #{SecureRandom.hex(4)}", account_type: "team")
    @disabled = Account.create!(name: "Disabled discovery #{SecureRandom.hex(4)}", account_type: "team",
      disabled_at: Time.current)
    clear_enqueued_jobs
  end

  teardown do
    [ @account, @disabled ].each(&:destroy!)
    @setting.update_columns(@original)
    clear_enqueued_jobs
  end

  test "every mutable panel setting enqueues one content-free fanout after commit" do
    {
      field_tweets_enabled: true, field_tweets_daily_import_cap: 25,
      field_tweets_poll_minutes: 30, field_tweets_account_monthly_usd_ceiling: 2,
      field_tweets_house_halted_at: Time.current
    }.each do |column, value|
      assert_enqueued_jobs 1, only: FieldTweets::RefreshSettingsJob do
        Setting.transaction do
          assert_no_enqueued_jobs only: FieldTweets::RefreshSettingsJob do
            @setting.update!(column => value)
            @setting.update!(site_name: "Later unrelated save")
            @setting.touch
            @setting.reload.save!
          end
        end
      end
    end
    assert_enqueued_with(job: FieldTweets::RefreshSettingsJob, args: []) do
      @setting.update!(field_tweets_enabled: false)
    end
    assert_enqueued_jobs 1, only: FieldTweets::RefreshSettingsJob do
      @setting.update!(field_tweets_house_halted_at: nil)
    end
  end

  test "only zero positive site ceiling transitions enqueue" do
    assert_no_enqueued_jobs only: FieldTweets::RefreshSettingsJob do
      @setting.update!(field_tweets_site_monthly_usd_ceiling: 20)
    end
    assert_enqueued_jobs 1, only: FieldTweets::RefreshSettingsJob do
      @setting.update!(field_tweets_site_monthly_usd_ceiling: 0)
    end
    assert_no_enqueued_jobs only: FieldTweets::RefreshSettingsJob do
      @setting.update!(field_tweets_site_monthly_usd_ceiling: 0)
    end
    assert_enqueued_jobs 1, only: FieldTweets::RefreshSettingsJob do
      @setting.update!(field_tweets_site_monthly_usd_ceiling: 1)
    end
  end

  test "unrelated settings halt reason no-ops and invalid saves do not enqueue" do
    assert_no_enqueued_jobs only: FieldTweets::RefreshSettingsJob do
      @setting.update!(site_name: "Elsewhere", field_tweets_house_halt_reason: "Not rendered",
        field_ocr_enabled: true, field_tweets_poll_minutes: 15)
      @setting.touch
      @setting.save!
      assert_not @setting.update(field_tweets_poll_minutes: 1)
    end
  end

  test "outer rollback and savepoint rollback discard fanout and later commits work" do
    assert_no_enqueued_jobs only: FieldTweets::RefreshSettingsJob do
      Setting.transaction do
        @setting.update!(field_tweets_enabled: true)
        raise ActiveRecord::Rollback
      end
      Setting.transaction do
        Setting.transaction(requires_new: true) do
          @setting.reload.update!(field_tweets_daily_import_cap: 3)
          raise ActiveRecord::Rollback
        end
        @setting.reload.touch
      end
      Setting.transaction do
        Setting.transaction(requires_new: true) { @setting.update!(field_tweets_enabled: true) }
        raise ActiveRecord::Rollback
      end
    end
    assert_enqueued_jobs 1, only: FieldTweets::RefreshSettingsJob do
      @setting.reload.update!(field_tweets_enabled: true)
    end
  end

  test "committed savepoint defers job until outer commit" do
    assert_enqueued_jobs 1, only: FieldTweets::RefreshSettingsJob do
      Setting.transaction do
        assert_no_enqueued_jobs only: FieldTweets::RefreshSettingsJob do
          Setting.transaction(requires_new: true) { @setting.update!(field_tweets_enabled: true) }
          @setting.touch
        end
      end
    end
  end

  test "real enqueue and perform chain emits exactly one marker per eligible account including no source" do
    assert_nil @account.field_tweet_source
    expected = Account.enabled.map { |account| [ "FieldTweetStream:#{account.to_param}", { action: "refresh" } ] }
    messages = capture_markers do
      perform_enqueued_jobs(only: FieldTweets::RefreshSettingsJob) do
        @setting.update!(field_tweets_enabled: true, field_tweets_daily_import_cap: 3)
      end
    end
    assert_equal expected.sort, messages.sort
    assert_equal 1, messages.count { |stream, _| stream == "FieldTweetStream:#{@account.to_param}" }
    assert_equal 0, messages.count { |stream, _| stream == "FieldTweetStream:#{@disabled.to_param}" }
    # Turning collection off must also hide already-open panels.
    assert_equal expected.sort, capture_markers {
      perform_enqueued_jobs(only: FieldTweets::RefreshSettingsJob) { @setting.update!(field_tweets_enabled: false) }
    }.sort
  end

  test "fanout does not require sources funding or tweet feature enabled but respects Field access" do
    expected = Account.enabled.count
    assert_equal expected, capture_markers { FieldTweets::RefreshSettingsJob.perform_now }.size
    @setting.update_columns(allow_agents: false)
    assert_empty capture_markers { FieldTweets::RefreshSettingsJob.perform_now }
  end

  private

  def capture_markers
    messages = []
    broadcast = ->(stream, payload) { messages << [ stream, payload ] if stream.start_with?("FieldTweetStream:") }
    ActionCable.server.stub(:broadcast, broadcast) { yield }
    messages
  end

end
