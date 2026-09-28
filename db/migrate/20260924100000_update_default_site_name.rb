class UpdateDefaultSiteName < ActiveRecord::Migration[8.1]
  def change
    change_column_default :settings, :site_name, from: "HelixKit", to: "souls.house"
  end
end
