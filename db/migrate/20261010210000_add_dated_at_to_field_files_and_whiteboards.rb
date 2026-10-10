# When a file or note is from, if that isn't when it arrived: an imported
# transcript from 2019, an old diary page. The Field orders by it when it is
# set, the way recordings already order by recorded_at.
class AddDatedAtToFieldFilesAndWhiteboards < ActiveRecord::Migration[8.1]

  def change
    add_column :field_files, :dated_at, :datetime
    add_column :whiteboards, :dated_at, :datetime
  end

end
