# The single row DeployAlarm writes: whether production follows master, as
# of the last check. Read by the Site Admin banner, the deploy menu and the
# dashboard; written only by DeployAlarm.check!.
class DeployAlarmState < ApplicationRecord

  state_machine :state, initial: :ok, action: nil do
    state :ok, :stuck, :unknown

    event :confirm_current do
      transition all => :ok
    end

    event :detect_stall do
      transition all => :stuck
    end

    event :lose_visibility do
      transition all => :unknown
    end
  end

  def self.current
    first || create!
  end

  def record_observation!(verdict, **attributes)
    case verdict
    when "ok" then confirm_current!
    when "stuck" then detect_stall!
    when "unknown" then lose_visibility!
    else raise ArgumentError, "Unknown deploy verdict: #{verdict}"
    end
    update!(attributes)
  end

  def short(sha)
    sha.to_s.first(7).presence
  end

  private

  private :confirm_current, :confirm_current!, :detect_stall, :detect_stall!,
    :lose_visibility, :lose_visibility!

end
