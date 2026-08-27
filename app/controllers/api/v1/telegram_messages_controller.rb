module Api
  module V1
    class TelegramMessagesController < BaseController

      MAX_MESSAGE_LENGTH = 4_000
      MAX_CAPTION_LENGTH = 1_024
      MAX_MEDIA_SIZE = 50.megabytes
      MAX_PHOTO_SIZE = 10.megabytes
      PHOTO_CONTENT_TYPES = %w[image/jpeg image/png].freeze
      PHOTO_FALLBACK_EXCLUSIONS = [ "blocked", "chat not found" ].freeze

      def create
        return render json: { error: "Telegram messaging is only available to agent API keys" }, status: :forbidden unless current_api_agent
        return render json: { error: "Telegram is not configured for this agent" }, status: :unprocessable_entity unless current_api_agent.telegram_configured?

        text = params[:text].to_s.strip
        media = params[:media]
        return render json: { error: "text or media is required" }, status: :unprocessable_entity if text.blank? && media.blank?
        return render json: { error: "media must be an uploaded file" }, status: :unprocessable_entity if media.present? && !media.respond_to?(:tempfile)

        maximum_length = media.present? ? MAX_CAPTION_LENGTH : MAX_MESSAGE_LENGTH
        label = media.present? ? "caption" : "text"
        return render json: { error: "#{label} is too long (max #{maximum_length} characters)" }, status: :unprocessable_entity if text.length > maximum_length
        return render json: { error: "media is too large (max 50 MB)" }, status: :unprocessable_entity if media.present? && media.size > MAX_MEDIA_SIZE

        subscriptions = target_subscriptions
        return render json: { error: "No matching active Telegram subscribers for this agent" }, status: :not_found if subscriptions.empty?

        content_type = detected_content_type(media) if media.present?
        media_kind = media_kind_for(media, content_type) if media.present?
        delivered = []
        blocked = []
        failures = []

        subscriptions.each do |subscription|
          outbound_message = nil

          begin
            outbound_message = build_outbound_message(subscription, text, media, media_kind, content_type)
            result = send_outbound_message(subscription, text, outbound_message, media)
            record_outbound_message(outbound_message, result)
            delivered << subscriber_json(subscription)
          rescue TelegramNotifiable::TelegramError => e
            outbound_message&.destroy!

            if e.message.include?("blocked") || e.message.include?("chat not found")
              subscription.mark_blocked!
              blocked << subscriber_json(subscription)
            else
              failures << subscriber_json(subscription).merge(error: e.message)
            end
          end
        end

        status = failures.any? ? :bad_gateway : :created
        render json: { delivered: delivered, blocked: blocked, failures: failures }, status: status
      end

      private

      def target_subscriptions
        scope = current_api_agent.telegram_subscriptions.active.includes(user: :profile)
        return [ scope.find(params[:reply_to]) ] if params[:reply_to].present?

        target = params[:recipient].presence || params[:to].presence
        needle = target.to_s.downcase.strip
        return scope.to_a if needle.blank? || needle == "all"

        scope.select do |subscription|
          user = subscription.user
          candidates = [
            subscription.telegram_username,
            user.email_address,
            user.first_name,
            user.last_name,
            user.full_name,
            user.profile&.first_name,
            user.profile&.last_name,
            user.profile&.full_name
          ].compact.map { |value| value.to_s.downcase }
          candidates.any? { |value| value.include?(needle) }
        end
      end

      def subscriber_json(subscription)
        user = subscription.user
        {
          user_id: user.to_param,
          thread_id: subscription.to_param,
          name: user.full_name.presence || user.email_address,
          email: user.email_address,
          telegram_username: subscription.telegram_username
        }
      end

      def build_outbound_message(subscription, text, media, media_kind, content_type)
        message = subscription.telegram_messages.build(
          role: "assistant",
          text: text.presence || media_placeholder(media_kind, media.original_filename),
          caption: text.presence,
          media_kind: media_kind,
          media_status: ("ready" if media.present?),
          media_metadata: media.present? ? media_metadata(media, content_type) : {},
          sender_name: current_api_agent.name,
          sent_at: Time.current
        )

        if media.present?
          media.tempfile.rewind
          message.media.attach(
            io: media.tempfile,
            filename: media.original_filename,
            content_type: content_type,
            identify: false
          )
        end

        message.save!
        message
      end

      def send_outbound_message(subscription, text, message, media)
        escaped_text = ERB::Util.html_escape(text)
        return current_api_agent.telegram_send_message(subscription.telegram_chat_id, escaped_text) unless message.media.attached?

        upload_options = {
          filename: message.media.filename.to_s,
          content_type: message.media.content_type,
          caption: escaped_text.presence
        }

        if message.photo?
          current_api_agent.telegram_send_photo(subscription.telegram_chat_id, media.tempfile, **upload_options)
        else
          current_api_agent.telegram_send_document(subscription.telegram_chat_id, media.tempfile, **upload_options)
        end
      rescue TelegramNotifiable::TelegramError => error
        raise unless message.photo? && retry_photo_as_document?(error)

        message.update!(
          media_kind: "document",
          text: text.presence || media_placeholder("document", message.media.filename.to_s)
        )
        current_api_agent.telegram_send_document(subscription.telegram_chat_id, media.tempfile, **upload_options)
      end

      def record_outbound_message(message, result)
        telegram_message = result["result"] || {}
        message.update!(
          telegram_message_id: telegram_message["message_id"],
          sent_at: telegram_message["date"] ? Time.zone.at(telegram_message["date"]) : Time.current
        )
      end

      def media_kind_for(media, content_type)
        return "photo" if PHOTO_CONTENT_TYPES.include?(content_type) && media.size <= MAX_PHOTO_SIZE

        "document"
      end

      def detected_content_type(media)
        media.tempfile.rewind
        Marcel::MimeType.for(
          media.tempfile,
          name: media.original_filename,
          declared_type: media.content_type
        )
      ensure
        media.tempfile.rewind
      end

      def media_metadata(media, content_type)
        {
          "content_type" => content_type,
          "byte_size" => media.size,
          "filename" => media.original_filename
        }
      end

      def media_placeholder(kind, filename)
        return "[Photo]" if kind == "photo"

        "[Document: #{filename}]"
      end

      def retry_photo_as_document?(error)
        description = error.message.downcase
        description.include?("bad request") &&
          PHOTO_FALLBACK_EXCLUSIONS.none? { |reason| description.include?(reason) }
      end

    end
  end
end
