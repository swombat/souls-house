# Why the house's upstream refused a call (#725): the provider's error type
# and message with every quoted span removed, capped at 300 characters
# (HouseInference::RefusalReason). Never the raw body, never the request.
# Kept on the refused call and on the run that made it, beside
# inference_refusal, so the Runs tab and the health check can read it.
class AddRefusalReasons < ActiveRecord::Migration[8.1]
  def change
    add_column :house_inference_calls, :refusal_reason, :string
    add_column :agent_runtime_interactions, :inference_refusal_reason, :string
  end
end
