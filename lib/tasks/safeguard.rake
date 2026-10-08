# Dry run for the conversation safeguard seam (docs/safeguard-conversations-spec.md §10).
# Read-only: nothing is written, nothing is reported to Honeybadger, and the
# output carries ids and counts only, never message bodies or people.
#
#   bin/rails safeguard:dry_run_conversations DAYS=30 MAX_CLASSIFY=200 SAMPLE_NEGATIVES=20
namespace :safeguard do
  desc "Report what the conversation safeguard check would have labelled (read-only)"
  task dry_run_conversations: :environment do
    days = Integer(ENV.fetch("DAYS", "30"))
    max_classify = Integer(ENV.fetch("MAX_CLASSIFY", "200"))
    sample_size = Integer(ENV.fetch("SAMPLE_NEGATIVES", "20"))

    report = SafeguardDryRun.new(days: days, max_classify: max_classify, sample_size: sample_size).call
    puts JSON.pretty_generate(report)
  end
end
