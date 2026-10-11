# Tweet streams into the Field: the house switch, limits and spend ledger.
# Collection itself is FieldTweets::Sync.
#
# Limits (Setting, admin-editable):
#   field_tweets_daily_import_cap: new tweets imported per account per UTC
#     day (default 50). Over it, returned tweets wait in the backlog.
#   field_tweets_account_monthly_usd_ceiling: house spend per account per
#     UTC calendar month (default $1).
#   field_tweets_site_monthly_usd_ceiling: house spend across all accounts
#     (default $0, so house-paid collection is shut until set).
#   own key: the source's own_monthly_usd_limit; no house ceiling, the same
#     import cap and retry limits.
#
# Every page is reserved before it is asked for, under one lock, at the most
# a page can cost, so two workers can't both take the last of a ceiling.
module FieldTweets

  LOCK_KEY = "field_tweet_ledger"
  # A reservation newer than this is a call still in flight.
  IN_FLIGHT = 10.minutes

  class LimitReached < StandardError; end

  # Not a setting. Test credentials might carry a key; tests turn this on
  # and use a fake client.
  mattr_accessor :live, default: true

  module_function

  def setting = Setting.instance

  def enabled? = live && setting.field_tweets_enabled

  def house_key
    Rails.application.credentials.dig(:twitterapi_io, :api_key).presence
  end

  def house_available?
    enabled? && house_key.present? && setting.field_tweets_house_halted_at.nil? &&
      setting.field_tweets_site_monthly_usd_ceiling.to_d.positive?
  end

  def daily_import_cap = setting.field_tweets_daily_import_cap
  def poll_interval = setting.field_tweets_poll_minutes.minutes

  def month_start(now = Time.current) = now.utc.beginning_of_month
  def day_start(now = Time.current) = now.utc.beginning_of_day

  def imported_today(account, now: Time.current)
    FieldTweet.where(account_id: account.id, created_at: day_start(now)..).count
  end

  def import_allowance_left(account, now: Time.current)
    [ daily_import_cap - imported_today(account, now: now), 0 ].max
  end

  def spent_this_month(scope, now: Time.current)
    scope.since(month_start(now)).sum(:charge_usd).to_d
  end

  # Halts every house-paid source: the house key itself was refused.
  def halt_house!(reason, now: Time.current)
    setting.update!(field_tweets_house_halted_at: now, field_tweets_house_halt_reason: reason.to_s.first(300))
  end

  def resume_house!
    setting.update!(field_tweets_house_halted_at: nil, field_tweets_house_halt_reason: nil)
  end

  # => a reserved FieldTweetCall for one page. Raises LimitReached with the
  # reason a person is shown.
  def reserve!(source, retry_call: false, now: Time.current)
    reserve = TwitterApiIo.page_reserve
    FieldTweetCall.transaction do
      FieldTweetCall.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{FieldTweetCall.connection.quote(LOCK_KEY)}))")

      if source.house_paid?
        raise LimitReached, "Tweet collection paid by the house is off" unless house_available?

        house = FieldTweetCall.where(funding: "house")
        if spent_this_month(house.where(account_id: source.account_id), now: now) + reserve > setting.field_tweets_account_monthly_usd_ceiling.to_d
          raise LimitReached, "This account's tweet collection budget for the month is used up"
        end
        if spent_this_month(house, now: now) + reserve > setting.field_tweets_site_monthly_usd_ceiling.to_d
          raise LimitReached, "The house's tweet collection budget for the month is used up"
        end
      else
        raise LimitReached, "Tweet collection is off" unless enabled?

        own = FieldTweetCall.where(funding: "own", account_id: source.account_id)
        if spent_this_month(own, now: now) + reserve > source.own_monthly_usd_limit.to_d
          raise LimitReached, "The limit set for this account's own key is used up for the month"
        end
      end

      FieldTweetCall.create!(account_id: source.account_id, field_tweet_source_id: source.id,
        funding: source.funding, status: "reserved", charge_usd: reserve, retry: retry_call)
    end
  end

  def status_json(now: Time.current)
    house = FieldTweetCall.where(funding: "house")
    {
      enabled: setting.field_tweets_enabled,
      house_key_configured: house_key.present?,
      house_halted_at: setting.field_tweets_house_halted_at&.iso8601,
      house_halt_reason: setting.field_tweets_house_halt_reason,
      site_monthly_usd_ceiling: setting.field_tweets_site_monthly_usd_ceiling.to_s,
      account_monthly_usd_ceiling: setting.field_tweets_account_monthly_usd_ceiling.to_s,
      daily_import_cap: daily_import_cap,
      poll_minutes: setting.field_tweets_poll_minutes,
      house_spent_this_month: spent_this_month(house, now: now).to_s,
      house_calls_this_month: house.since(month_start(now)).count,
      returned_this_month: house.since(month_start(now)).sum(:returned_count),
      already_stored_this_month: house.since(month_start(now)).sum(:already_stored_count)
    }
  end

end
