# The matching snapshot (FieldVoiceprints::Cohort key) an account's recordings
# were last all matched against. Unchecked prints give hints, so any cohort
# change is reason to match again, including one made before the check ran
# (Mira's review of #479).
class AddFieldMatchedCohortToAccounts < ActiveRecord::Migration[8.1]

  def change
    add_column :accounts, :field_matched_cohort, :string
  end

end
