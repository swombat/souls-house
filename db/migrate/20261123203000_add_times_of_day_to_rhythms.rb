class AddTimesOfDayToRhythms < ActiveRecord::Migration[8.0]

  def change
    add_column :rhythms, :times_of_day, :jsonb
  end

end
