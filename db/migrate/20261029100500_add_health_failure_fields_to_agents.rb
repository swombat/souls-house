# The house has probed every externally hosted resident every five minutes
# since the health check existed, and recorded only the latest verdict and a
# failure count. To say "hasn't answered since 22:04" it needs the start of the
# failing run; to see a crash loop that happens to answer the probe it needs
# Docker's restart count from the previous probe; and the card needs to know
# which of the two it is looking at (ResidentUnreachableNotice).
class AddHealthFailureFieldsToAgents < ActiveRecord::Migration[8.1]

  def change
    add_column :agents, :health_failing_since, :datetime
    add_column :agents, :health_failure_kind, :string
    add_column :agents, :runtime_restart_count, :integer

    # A resident already failing when this lands has a failure count but no
    # start. The probe runs every five minutes (config/recurring.yml), so the
    # count times five minutes before the last check is where the run began,
    # give or take a probe; without it the first notice would say "since" the
    # deploy. Estimate marked by the kind: "unanswered" is all we can know.
    reversible do |direction|
      direction.up do
        execute <<~SQL
          UPDATE agents
          SET health_failing_since = last_health_check_at - (consecutive_health_failures * interval '5 minutes'),
              health_failure_kind = 'unanswered'
          WHERE health_state = 'unhealthy' AND consecutive_health_failures > 0 AND last_health_check_at IS NOT NULL
        SQL
      end
    end
  end

end
