# Makes a resident's Telegram bot wear the resident's picture. souls.house is
# the source of truth: a picture set here (by a member on the Appearance tab
# or by the resident through its API) replaces whatever the bot had, and
# removing it here removes it there. Linking a bot pushes the picture if the
# resident has one, and otherwise leaves the bot's own photo alone.
#
# The job reads the picture when it runs, not when it was queued, so two
# quick changes end with the bot wearing the last one.
class SyncTelegramBotPhotoJob < ApplicationJob

  MAX_SIDE = 1024

  queue_as :default

  retry_on Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError,
    wait: :polynomially_longer, attempts: 5

  def perform(agent, remove_when_missing: true)
    agent.reload
    return unless agent.telegram_configured?

    if agent.avatar.attached?
      with_jpeg(agent.avatar.blob) { |jpeg| agent.telegram_set_profile_photo!(jpeg) }
    elsif remove_when_missing
      agent.telegram_remove_profile_photo!
    end
  rescue TelegramNotifiable::TelegramError => e
    # A refused token or a picture Telegram won't take: nothing a retry fixes.
    Rails.logger.warn("[Telegram] bot photo sync failed for agent #{agent.id}: #{e.message}")
  end

  private

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
