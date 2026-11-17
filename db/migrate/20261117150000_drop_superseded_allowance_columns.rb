# Columns nothing has read since the allowance became the account's (11 Nov)
# and the plan's transcription hours replaced the weekly limit. Both models
# have ignored them since then, so the running release never selects them.
class DropSupersededAllowanceColumns < ActiveRecord::Migration[8.1]
  def change
    remove_column :resident_entitlements, :allowance_month, :date
    remove_column :resident_entitlements, :allowance_limit_usd, :decimal, precision: 14, scale: 8
    remove_column :accounts, :recording_ms_weekly_limit, :bigint, default: 72_000_000, null: false
  end
end
