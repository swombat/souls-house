# One reader call in a Field swarm search: one part of one item, with the
# tokens and cost OpenRouter reported. `read` means the model answered;
# `failed` and `rate_limited` mean it didn't, and that part of the item was
# not checked.
class FieldSwarmRead < ApplicationRecord

  STATUSES = %w[read failed rate_limited].freeze

  belongs_to :field_swarm_search
  belongs_to :account

  validates :status, inclusion: { in: STATUSES }

end
