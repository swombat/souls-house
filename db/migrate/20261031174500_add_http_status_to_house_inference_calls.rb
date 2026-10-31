# A refused house call keeps its HTTP status (never its body), so a refusal
# can be told apart from a timeout when reading the ledger.
class AddHttpStatusToHouseInferenceCalls < ActiveRecord::Migration[8.1]

  def change
    add_column :house_inference_calls, :http_status, :integer
  end

end
