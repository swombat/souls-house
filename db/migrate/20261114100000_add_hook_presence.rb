class AddHookPresence < ActiveRecord::Migration[8.1]

  # jaMBVj: a run records whether the resident's expected Chaos hooks were
  # present and fired. The report itself rides in response_body.telemetry.hooks;
  # hook_warning is the plain reason when an expectation went unmet.
  def change
    add_column :agent_runtime_interactions, :hook_warning, :text
    # { "session_start" => { "state" => "expected"|"off", "source" => "observed"|"owner"|"resident", "at" => iso8601 } }
    add_column :agents, :hook_expectations, :jsonb, default: {}, null: false
  end

end
