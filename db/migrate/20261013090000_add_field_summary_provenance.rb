class AddFieldSummaryProvenance < ActiveRecord::Migration[8.1]

  def change
    %i[field_files field_recordings].each do |table|
      add_column table, :summary_input_digest, :string, limit: 64
      add_column table, :summary_refresh_digest, :string, limit: 64
      add_column table, :summary_claim_token, :string
      add_column table, :summary_refresh_due_at, :datetime
    end
  end

end
