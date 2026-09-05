module Chat::Summarizable

  extend ActiveSupport::Concern

  SUMMARY_COOLDOWN = 1.hour

  def summary_stale?
    summary_generated_at.nil? || summary_generated_at < SUMMARY_COOLDOWN.ago
  end

  def transcript_for_api(after_message_id: nil, since: nil)
    scope = messages.includes(:user, :agent, attachments_attachments: :blob)
                     .where(role: %w[user assistant])
                     .order(:created_at)
    scope = scope.where("messages.id > ?", after_message_id) if after_message_id.present?
    since_time = parse_since(since)
    scope = scope.where("messages.created_at > ?", since_time) if since_time

    scope.map { |message| format_message_for_api(message) }
  end

  private

  def parse_since(value)
    return nil if value.blank?
    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  def format_message_for_api(message)
    {
      id: message.to_param,
      role: message.role,
      content: message.content,
      author: api_author_name(message),
      timestamp: message.created_at.iso8601,
      attachments: message.attachments_for_api
    }
  end

  def api_author_name(message)
    if message.agent.present?
      message.agent.name
    elsif message.user.present?
      message.user.full_name.presence || message.user.email_address.split("@").first
    else
      message.role.titleize
    end
  end

end
