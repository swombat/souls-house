module TelegramNotifiable

  extend ActiveSupport::Concern

  class TelegramError < StandardError; end
  class TelegramMediaError < TelegramError; end
  class TelegramMediaTransientError < TelegramMediaError; end
  class TelegramMediaPermanentError < TelegramMediaError; end
  class TelegramMediaTooLarge < TelegramMediaPermanentError; end
  class TelegramMediaInvalid < TelegramMediaPermanentError; end

  DownloadedTelegramFile = Struct.new(:tempfile, :file_path, :byte_size, keyword_init: true)

  included do
    has_many :telegram_subscriptions, dependent: :destroy
    has_many :telegram_messages, through: :telegram_subscriptions

    encrypts :telegram_bot_token

    validates :telegram_bot_username, format: { with: /\A[a-zA-Z0-9_]+\z/ }, allow_blank: true

    before_save :set_telegram_webhook_token, if: :telegram_bot_token_changed?
    after_update_commit :manage_telegram_webhook, if: -> { saved_change_to_telegram_bot_token? || saved_change_to_telegram_bot_username? }
  end

  def telegram_configured?
    telegram_bot_token.present? && telegram_bot_username.present?
  end

  def telegram_send_message(chat_id, text, **options)
    body = { chat_id: chat_id, text: text, parse_mode: "HTML" }.merge(options)
    result = telegram_api_request("sendMessage", body)

    raise TelegramError, result["description"] unless result["ok"]

    result
  end

  def telegram_send_photo(chat_id, photo, filename:, content_type:, caption: nil)
    telegram_send_media(
      "sendPhoto",
      chat_id,
      :photo,
      photo,
      filename: filename,
      content_type: content_type,
      caption: caption
    )
  end

  def telegram_send_document(chat_id, document, filename:, content_type:, caption: nil)
    telegram_send_media(
      "sendDocument",
      chat_id,
      :document,
      document,
      filename: filename,
      content_type: content_type,
      caption: caption
    )
  end

  def telegram_file_info(file_id)
    result = telegram_api_request("getFile", { file_id: file_id })
    return result.fetch("result") if result["ok"] && result.dig("result", "file_path").present?

    description = result["description"].to_s
    if description.downcase.include?("file is too big")
      raise TelegramMediaTooLarge, "Telegram refused an oversized file"
    end

    error_code = result["error_code"].to_i
    if error_code.between?(400, 499) && error_code != 429
      raise TelegramMediaInvalid, "Telegram rejected the file identifier"
    end

    raise TelegramMediaTransientError, "Telegram could not provide file information"
  rescue TelegramMediaError
    raise
  rescue StandardError => e
    raise TelegramMediaTransientError, "Telegram file information request failed: #{e.class}"
  end

  def telegram_download_file(file_path, max_bytes:)
    tempfile = Tempfile.new([ "telegram-media-", File.extname(file_path) ], binmode: true)
    uri = URI("https://api.telegram.org/file/bot#{telegram_bot_token}/#{file_path}")
    byte_size = 0

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 60, open_timeout: 10) do |http|
      http.request_get(uri.request_uri) do |response|
        unless response.is_a?(Net::HTTPSuccess)
          raise TelegramMediaTooLarge, "Telegram media exceeded the application limit" if response.code.to_i == 413
          if response.code.to_i.between?(400, 499) && response.code.to_i != 429
            raise TelegramMediaInvalid, "Telegram media is no longer available"
          end

          raise TelegramMediaTransientError, "Telegram media download returned HTTP #{response.code}"
        end

        response.read_body do |chunk|
          byte_size += chunk.bytesize
          raise TelegramMediaTooLarge, "Telegram media exceeded the application limit" if byte_size > max_bytes

          tempfile.write(chunk)
        end
      end
    end

    tempfile.rewind
    DownloadedTelegramFile.new(tempfile: tempfile, file_path: file_path, byte_size: byte_size)
  rescue TelegramMediaError
    tempfile&.close!
    raise
  rescue StandardError => e
    tempfile&.close!
    raise TelegramMediaTransientError, "Telegram media download failed: #{e.class}"
  end

  def set_telegram_webhook!
    return unless telegram_configured?

    webhook_url = "#{Rails.application.credentials.dig(:app, :url)}/telegram/webhook/#{telegram_webhook_token}"
    result = telegram_api_request("setWebhook", {
      url: webhook_url,
      allowed_updates: [ "message", "callback_query" ],
      secret_token: telegram_webhook_secret
    })

    Rails.logger.error("[Telegram] setWebhook failed for agent #{id}: #{result['description']}") unless result["ok"]
  end

  def telegram_webhook_info
    return nil unless telegram_bot_token.present?
    telegram_api_request("getWebhookInfo", {})
  end

  def telegram_answer_callback_query(callback_query_id, text: nil)
    body = { callback_query_id: callback_query_id }
    body[:text] = text if text.present?
    result = telegram_api_request("answerCallbackQuery", body)
    raise TelegramError, result["description"] unless result["ok"]

    result
  end

  def delete_telegram_webhook!
    return unless telegram_bot_token.present?

    result = telegram_api_request("deleteWebhook", { drop_pending_updates: true })

    Rails.logger.error("[Telegram] deleteWebhook failed for agent #{id}: #{result['description']}") unless result["ok"]
  end

  def telegram_webhook_secret
    Base64.urlsafe_encode64(
      Rails.application.key_generator.generate_key("telegram_webhook_secret:#{id}", 32),
      padding: false
    )
  end

  def notify_subscribers!(message, chat)
    return unless telegram_configured?
    return if chat.agent_only?

    telegram_subscriptions.active.each do |subscription|
      TelegramNotificationJob.perform_later(subscription, message, chat)
    end
  end

  def telegram_deep_link_for(user)
    # Telegram deep link params only allow [A-Za-z0-9_] and max 64 chars,
    # so we store a short random token in Rails cache instead of signing
    token = SecureRandom.alphanumeric(32)
    Rails.cache.write("telegram_deep_link:#{token}", { user_id: user.id, agent_id: id }, expires_in: 7.days)
    "https://t.me/#{telegram_bot_username}?start=#{token}"
  end

  private

  def telegram_send_media(method, chat_id, media_key, media, filename:, content_type:, caption:)
    media.rewind
    form = [ [ "chat_id", chat_id.to_s ] ]
    form.concat([ [ "caption", caption ], [ "parse_mode", "HTML" ] ]) if caption.present?
    form << [ media_key.to_s, media, { filename: filename, content_type: content_type } ]

    uri = telegram_api_uri(method)
    request = Net::HTTP::Post.new(uri)
    request.set_form(form, "multipart/form-data")
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(request)
    end
    result = JSON.parse(response.body)

    raise TelegramError, result["description"] unless result["ok"]

    result
  end

  def telegram_api_request(method, body)
    uri = telegram_api_uri(method)
    response = Net::HTTP.post(uri, body.to_json, "Content-Type" => "application/json")
    JSON.parse(response.body)
  end

  def telegram_api_uri(method)
    URI("https://api.telegram.org/bot#{telegram_bot_token}/#{method}")
  end

  def set_telegram_webhook_token
    if telegram_bot_token.present?
      self.telegram_webhook_token ||= SecureRandom.hex(16)
    else
      self.telegram_webhook_token = nil
    end
  end

  def manage_telegram_webhook
    ManageTelegramWebhookJob.perform_later(self)
  end

end
