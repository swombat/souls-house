# Minimal provider evidence, retained beyond the UI cache's expiry so a known
# low allowance continues to protect its window during a telemetry outage.
class AllowanceBrakeReading < ApplicationRecord

  belongs_to :agent

end
