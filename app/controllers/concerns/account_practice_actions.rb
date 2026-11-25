# What the practices page and /api/v1/account_practices share: reading the
# params and shaping the list.
module AccountPracticeActions

  extend ActiveSupport::Concern

  private

  def practice_text_param
    value = params[:text]
    value.is_a?(String) ? value : nil
  end

  def practice_position_param
    value = params[:position]
    return if value.blank?

    Integer(value.to_s, 10)
  rescue ArgumentError
    nil
  end

  def practices_payload(account)
    practices = account.account_practices.ordered.includes(:updated_by_user, :updated_by_agent).to_a
    {
      limits: { max_length: AccountPractice::MAX_LENGTH, max_lines: AccountPractice::MAX_LINES, max_total: AccountPractice::MAX_TOTAL },
      used: practices.sum { |practice| practice.text.length },
      practices: practices.map(&:as_json)
    }
  end

  def practice_request_context
    credential = if @current_api_key
      { api_key_id: @current_api_key.id }
    elsif @current_app_session
      { app_session_id: @current_app_session.id }
    else
      {}
    end
    { ip_address: request.remote_ip, user_agent: request.user_agent, credential: }
  end

end
