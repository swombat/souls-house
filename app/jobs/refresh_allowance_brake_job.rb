class RefreshAllowanceBrakeJob < ApplicationJob

  def perform(id)
    reading = AllowanceBrakeReading.find_by(id: id)
    return unless reading && !reading.agent.allowance_brake_threshold_percent.nil?
    Agents::AllowanceBrake.refresh!(reading)
  rescue AgentProviderAuthClient::Error => error
    Rails.logger.info("[AllowanceBrake] refresh unavailable reading=#{id} #{error.class}")
  end

end
