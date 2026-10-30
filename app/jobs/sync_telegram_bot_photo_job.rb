# Makes a resident's Telegram bot wear the resident's picture. souls.house is
# the source of truth: a picture set here (by a member on the Appearance tab
# or by the resident through its API) replaces whatever the bot had, and
# removing it here removes it there. Linking a bot pushes the picture if the
# resident has one, and otherwise leaves the bot's own photo alone.
#
# Last change wins: one sync runs at a time per resident (limits_concurrency),
# and each reads the picture when it runs, not when it was queued. Without the
# limit an older upload could finish after a newer one and leave the old face.
class SyncTelegramBotPhotoJob < ApplicationJob

  MAX_SIDE = 1024
  ATTEMPTS = 5

  queue_as :default

  limits_concurrency to: 1, key: ->(agent, **) { "telegram-bot-photo-#{agent.id}" }, duration: 5.minutes

  retry_on Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError, JSON::ParserError,
    wait: :polynomially_longer, attempts: ATTEMPTS

  def perform(agent, remove_when_missing: true)
    agent.reload
    return unless agent.telegram_configured?

    if agent.avatar.attached?
      with_jpeg(agent.avatar.blob) { |jpeg| agent.telegram_set_profile_photo!(jpeg) }
    elsif remove_when_missing
      agent.telegram_remove_profile_photo!
    end
  rescue TelegramNotifiable::TelegramRetryableError => e
    # Flood control or Telegram's own trouble: try again, after the wait
    # Telegram asks for when it gives one, a bounded number of times.
    return give_up(agent, e) if executions >= ATTEMPTS

    retry_job(wait: e.retry_after ? e.retry_after.to_i.seconds + 1.second : (executions**2 * 15).seconds)
  rescue TelegramNotifiable::TelegramError => e
    # A refused token or a picture Telegram won't take: nothing a retry fixes.
    give_up(agent, e)
  end

  private

  def give_up(agent, error)
    Rails.logger.warn("[Telegram] bot photo sync failed for agent #{agent.id}: #{error.message}")
  end

  # Telegram takes a static profile photo only as JPEG.
  def with_jpeg(blob)
    blob.open do |source|
      jpeg = ImageProcessing::Vips.source(source).resize_to_limit(MAX_SIDE, MAX_SIDE).convert("jpg").call
      begin
        yield jpeg
      ensure
        jpeg.close!
      end
    end
  end

end
