class RhythmSweepJob < ApplicationJob

  def perform
    now = Time.current
    Rhythm.due(now).find_each do |rhythm|
      rhythm.fire!(now: now)
    rescue StandardError => error
      Rails.logger.error "[RhythmSweepJob] rhythm #{rhythm.id}: #{error.class}: #{error.message}"
    end
  end

end
