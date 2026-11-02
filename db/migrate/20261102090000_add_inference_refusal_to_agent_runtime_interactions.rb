# The house inference gateway's refusal of a call made during this run
# (#678): "house_allowance_exhausted" or "house_allowance_none". Written by
# the gateway against the run named in the call's X-Soulshouse-Run header,
# after checking the run belongs to the calling resident and is unfinished.
class AddInferenceRefusalToAgentRuntimeInteractions < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runtime_interactions, :inference_refusal, :string
  end
end
