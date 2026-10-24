# Tweet streams into the Field: the house switch, limits and spend ledger.
# Collection itself is FieldTweets::Sync.
#
# Limits (Setting, admin-editable):
#   field_tweets_daily_import_cap: new tweets imported per account per UTC
#     day (default 50). Over it, returned tweets wait in the backlog.
#   field_tweets_account_monthly_usd_ceiling: house spend per account per
#     UTC calendar month (default $1).
#   field_tweets_site_monthly_usd_ceiling: house spend across all accounts
#     (default $10).
#   own key: the source's own_monthly_usd_limit; no house ceiling, the same
#     import cap and retry limits.
#
# Who pays (Daniel, 2026-10-14): the account's own TwitterAPI.io integration
# (a ServiceConnection, Settings → Integrations) when it has one; otherwise
# the house key, but only for accounts a site admin has granted it
# (accounts.field_tweets_house_key, like the shared AI credentials);
# otherwise nobody, and nothing is collected. An account with an integration
# never falls back to the house, even while its key is refused.
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

  def house_available_for?(account) = account.field_tweets_house_key? && house_available?

  NO_FUNDING = "You need to set up a TwitterAPI.io integration first"

  # The account's own TwitterAPI.io connection, if it has a working one.
  def integration_for(account)
    account.service_connections.account_managed.connected.where(provider: "twitterapi_io").order(:id).last
  end

  # "own", "house" or nil (nobody pays, nothing is collected).
  def funding_for(account)
    return "own" if integration_for(account)
    return "house" if account.field_tweets_house_key?

    nil
  end

  def key_for(account, funding)
    case funding
    when "own" then integration_for(account)&.credential_payload_hash&.dig("api_key").presence
    when "house" then house_key
    end
  end

  # A change to who pays (an integration added, removed or given a new key;
  # the house grant turned on or off) is a person's act: a stream stopped
  # for its key, or waiting for someone to pay, tries again now. Paused
  # streams stay paused. Not called for edits that change nothing about
  # paying (ServiceConnection#tweet_funding_changed?).
  def integration_changed!(account)
    source = FieldTweetSource.find_by(account_id: account.id) or return
    if source.state == "needs_attention"
      source.resume!
    elsif source.state == "active"
      source.update!(next_attempt_at: Time.current)
    end
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

      # Read fresh under the lock: a grant revoked or an integration removed
      # since the run began stops the next page, not just the next run.
      account = Account.find(source.account_id)
      funding = funding_for(account)
      raise LimitReached, NO_FUNDING if funding.nil?

      if funding == "house"
        raise LimitReached, "Tweet collection paid by the house is off" unless house_available_for?(account)

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
        funding: funding, status: "reserved", charge_usd: reserve, retry: retry_call)
    end
  end

  def status_json(now: Time.current)
    house = FieldTweetCall.where(funding: "house")
    {
      enabled: setting.field_tweets_enabled,
      house_key_configured: house_key.present?,
      house_key_accounts: Account.where(field_tweets_house_key: true).count,
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
