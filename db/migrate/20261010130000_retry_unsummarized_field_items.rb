# Field summaries went live with two faults (2026-10-10): Haiku sometimes spent
# its whole token budget reasoning and answered nothing, and its short summary
# was often six or seven words, which was refused. Items that hit either used
# up their three attempts and were given up on. Both are fixed; give every
# unsummarised item its attempts back so the hourly sweep tries again. Blank
# items are retired again at no cost when claimed.
class RetryUnsummarizedFieldItems < ActiveRecord::Migration[8.1]

  def up
    %w[field_files field_recordings].each do |table|
      execute "UPDATE #{table} SET summary_attempts = 0, summary_claimed_at = NULL WHERE summarized_at IS NULL AND summary_attempts > 0"
    end
  end

  def down; end

end
