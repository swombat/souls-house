# The transcription allowance now comes from the account's plan. This is a
# site admin's override for one account; null means the plan's number. The
# old flat weekly column (recording_ms_weekly_limit) is no longer read and is
# dropped in a later release, once no running code selects it.
class AddTranscriptionMsLimitOverrideToAccounts < ActiveRecord::Migration[8.1]

  def change
    add_column :accounts, :transcription_ms_limit_override, :bigint
  end

end
