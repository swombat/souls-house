# The single row DeployAlarm writes: whether production follows master, as
# of the last check. Read by the Site Admin banner, the deploy menu and the
# dashboard; written only by DeployAlarm.check!.
class DeployAlarmState < ApplicationRecord

  STATES = %w[ok stuck unknown].freeze

  validates :state, inclusion: { in: STATES }

  def self.current
    first || create!(state: "ok")
  end

  def short(sha)
    sha.to_s.first(7).presence
  end

end
