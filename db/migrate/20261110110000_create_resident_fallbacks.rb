class CreateResidentFallbacks < ActiveRecord::Migration[8.1]

  # #690: a resident whose subscription allowance has run out may answer on a
  # model billed to the account's own OpenRouter key, only after an owner opts
  # in. Off by default. Spending is enforced per provider call: each call
  # reserves its worst case against the owner's cap before it is sent, and
  # settles to the provider-reported cost.
  def change
    create_table :resident_fallback_policies do |t|
      t.references :agent, null: false, foreign_key: true, index: { unique: true }
      t.boolean :enabled, null: false, default: false
      t.string :model_id
      t.decimal :cap_usd, precision: 10, scale: 2
      t.string :cap_period, null: false, default: "month"
      # Whose key pays. v1 knows one: the account's own OpenRouter key.
      t.string :payer, null: false, default: "openrouter"
      t.references :enabled_by_user, foreign_key: { to_table: :users }
      t.datetime :enabled_at
      t.timestamps
      t.check_constraint "cap_usd IS NULL OR (cap_usd > 0 AND cap_usd <> 'NaN'::numeric)", name: "fallback_policies_positive_cap"
    end

    # One logical turn that hopped: the refused subscription attempt and the
    # paid attempt, linked. Attribution reads the dispatched attempt, never
    # the current policy.
    create_table :resident_fallback_turns do |t|
      t.references :agent, null: false, foreign_key: true
      # The ledger outlives the room and the run log: spending stays counted.
      t.references :chat, foreign_key: { on_delete: :nullify }
      t.references :primary_interaction, foreign_key: { to_table: :agent_runtime_interactions, on_delete: :nullify }
      t.references :fallback_interaction, foreign_key: { to_table: :agent_runtime_interactions, on_delete: :nullify },
        index: { unique: true }
      t.string :primary_provider, null: false
      t.string :primary_model, null: false
      t.string :fallback_model_id, null: false
      t.string :upstream_model, null: false
      # When the subscription said its blocking window resets: a hint for
      # when to try the subscription route first, not proof it has recovered.
      t.datetime :primary_resets_at
      t.timestamps
    end

    # Every paid provider call. Rates are snapshotted per call; history is
    # never repriced from mutable catalogue data.
    create_table :resident_fallback_calls do |t|
      t.references :agent, null: false, foreign_key: true
      t.references :resident_fallback_turn, foreign_key: { on_delete: :nullify }
      # When the call was admitted. The cap window is computed from this at
      # read time, so changing the cap period never forgets calls inside the
      # new window.
      t.datetime :admitted_at, null: false
      t.string :upstream_model, null: false
      t.jsonb :max_price, null: false
      t.bigint :input_bound_tokens, null: false
      t.bigint :max_output_tokens, null: false
      t.decimal :reservation_usd, precision: 14, scale: 8, null: false
      # Provider-reported (OpenRouter usage.cost, BYOK fee + upstream cost).
      t.decimal :charge_usd, precision: 14, scale: 8
      t.string :cost_source
      # pending: in flight, reservation held. settled: the provider reported
      # the charge. not_sent: refused before leaving the house, costs nothing.
      # unresolved: may have reached the provider, charge unknown; the
      # reservation stays counted.
      t.string :status, null: false, default: "pending"
      t.integer :http_status
      t.string :upstream_id
      t.timestamps
      # PostgreSQL sorts NaN above every number, so ">= 0" alone admits it.
      t.check_constraint "reservation_usd >= 0 AND reservation_usd <> 'NaN'::numeric AND " \
        "(charge_usd IS NULL OR (charge_usd >= 0 AND charge_usd <> 'NaN'::numeric))",
        name: "fallback_calls_nonnegative"
      t.check_constraint "status <> 'settled' OR charge_usd IS NOT NULL",
        name: "fallback_calls_settled_have_charge"
    end
    add_index :resident_fallback_calls, [ :agent_id, :admitted_at ]
  end

end
