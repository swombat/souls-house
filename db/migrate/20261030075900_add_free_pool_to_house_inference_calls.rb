# Whether a house call is paid out of a free allowance (the per-user grants and
# free hosting's own allowance), fixed when the call is reserved. The
# house-wide ceiling sums these. Deriving it from the entitlement's current
# state would move past spend between pools whenever a plan starts or ends
# (Mira, #661). Before free hosting funded calls, only grant calls were free.
class AddFreePoolToHouseInferenceCalls < ActiveRecord::Migration[8.1]

  def up
    add_column :house_inference_calls, :free_pool, :boolean
    execute "UPDATE house_inference_calls SET free_pool = (house_inference_grant_id IS NOT NULL)"
    change_column_null :house_inference_calls, :free_pool, false
    add_index :house_inference_calls, [ :month, :free_pool ], name: "index_house_calls_on_month_free_pool"
  end

  def down
    remove_index :house_inference_calls, name: "index_house_calls_on_month_free_pool"
    remove_column :house_inference_calls, :free_pool
  end

end
