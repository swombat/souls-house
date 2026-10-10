# Two machine-written summaries per Field file and recording (a few words, and
# one sentence), written by FieldItems::SummarizeJob once the item's words are
# readable. summary_attempts counts claimed calls, so a broken item costs at
# most FieldSummarizable::MAX_ATTEMPTS calls, ever.
class AddSummariesToFieldItems < ActiveRecord::Migration[8.1]

  def change
    %i[field_files field_recordings].each do |table|
      change_table table, bulk: true do |t|
        t.string :summary_short, limit: 80
        t.string :summary_long, limit: 400
        t.datetime :summarized_at
        t.datetime :summary_claimed_at
        t.integer :summary_attempts, null: false, default: 0
      end
    end
  end

end
