# One reader call in a Field swarm search: one part of one item, with the
# tokens and cost OpenRouter reported. `read` means the model answered;
# `failed`, `rate_limited` and `timed_out` mean it didn't, and that part of
# the item was not checked. `cost_uncertain` marks a call that was sent but
# whose cost didn't come back: it may have been billed.
class FieldSwarmRead < ApplicationRecord

  STATUSES = %w[read failed rate_limited timed_out].freeze

  belongs_to :field_swarm_search
  belongs_to :account

  validates :status, inclusion: { in: STATUSES }

end
