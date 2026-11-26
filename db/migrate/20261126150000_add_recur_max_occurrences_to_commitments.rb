# An optional ceiling on a recurring series (Reed, eRNlOe eaMwXx): after
# this many occurrences it stops by itself and says why, so a goal that
# stays blocked cannot wake a resident all night.
class AddRecurMaxOccurrencesToCommitments < ActiveRecord::Migration[8.1]

  def change
    add_column :commitments, :recur_max_occurrences, :integer
  end

end
