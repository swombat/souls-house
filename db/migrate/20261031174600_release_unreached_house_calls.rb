# A house call that failed before any generation reached the resident costs
# the resident nothing (Daniel, JwMQEe, 2026-10-31). Until now every failure
# but OpenRouter's 404 routing refusal kept its $0.75 reservation as
# "uncertain", and nothing reconciled it. On 31 Oct prod held 31 such rows,
# all failing in under a second with no upstream generation id; 26 were Soul
# Horse's, most of her free allowance. This releases every uncertain call with
# no upstream id: without one, no model output reached anyone. Calls with an
# id (the model ran and may have been billed) are left for reconciliation.
class ReleaseUnreachedHouseCalls < ActiveRecord::Migration[8.1]

  def up
    execute <<~SQL
      UPDATE house_inference_calls
      SET charge_usd = 0, status = 'released', updated_at = NOW()
      WHERE status = 'uncertain' AND upstream_id IS NULL
    SQL
  end

  def down
    # Released rows can't be told apart from later releases; the charges are
    # not reinstated.
  end

end
