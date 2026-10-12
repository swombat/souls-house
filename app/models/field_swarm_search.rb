# One Field swarm search (FieldSwarm) and what it cost. Kept so a site admin
# can see, after a couple of weeks of testing, how much the feature costs in
# total, per search and per account (Site Admin → Accounts).
class FieldSwarmSearch < ApplicationRecord

  STATUSES = %w[running complete failed].freeze

  belongs_to :account
  belongs_to :agent, optional: true
  belongs_to :user, optional: true
  has_many :reads, class_name: "FieldSwarmRead", dependent: :delete_all

  validates :status, inclusion: { in: STATUSES }

  # Totals over a scope of searches, for the admin page.
  def self.totals(scope = all)
    searches, cost, reads, input_tokens, output_tokens, uncertain, last = scope.pick(
      Arel.sql("count(*)"), Arel.sql("coalesce(sum(cost_usd), 0)"),
      Arel.sql("coalesce(sum(completed_reads + failed_reads), 0)"),
      Arel.sql("coalesce(sum(input_tokens), 0)"), Arel.sql("coalesce(sum(output_tokens), 0)"),
      Arel.sql("coalesce(sum(uncertain_cost_reads), 0)"), Arel.sql("max(created_at)")
    )
    cost = cost.to_d
    {
      searches: searches, reads: reads, cost_usd: cost.round(6).to_s("F"),
      cost_per_search_usd: (searches.positive? ? (cost / searches).round(6).to_s("F") : nil),
      cost_per_read_usd: (reads.positive? ? (cost / reads).round(6).to_s("F") : nil),
      input_tokens: input_tokens, output_tokens: output_tokens, uncertain_cost_reads: uncertain,
      last_at: last&.iso8601
    }
  end

end
