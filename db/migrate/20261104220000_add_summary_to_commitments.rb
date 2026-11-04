# A short headline for a commitment (Daniel, JVvqyJ): the "Commitment due"
# message shows this instead of the whole text. Nullable: older rows and
# callers that do not send one fall back to a headline cut from the text.
class AddSummaryToCommitments < ActiveRecord::Migration[8.1]

  def change
    add_column :commitments, :summary, :string
  end

end
