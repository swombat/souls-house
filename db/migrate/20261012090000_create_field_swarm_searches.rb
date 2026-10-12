class CreateFieldSwarmSearches < ActiveRecord::Migration[8.1]

  def change
    # Off for every account until a site admin turns it on (Site Admin →
    # Accounts). A test feature while its cost is measured.
    add_column :accounts, :field_swarm_enabled, :boolean, null: false, default: false

    # One swarm search: who asked, what was asked, how many items matched and
    # were read, and what it cost.
    create_table :field_swarm_searches do |t|
      t.references :account, null: false, foreign_key: true
      # Kept when the resident or person is deleted; the cost stays on the books.
      t.references :agent, foreign_key: { on_delete: :nullify }
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :status, null: false, default: "running"
      t.jsonb :tags, null: false, default: []
      t.text :grep
      t.integer :question_chars, null: false
      t.integer :matched_items, null: false, default: 0
      t.integer :candidate_items, null: false, default: 0
      t.integer :planned_reads, null: false, default: 0
      t.integer :completed_reads, null: false, default: 0
      t.integer :failed_reads, null: false, default: 0
      t.integer :unrun_reads, null: false, default: 0
      t.integer :uncertain_cost_reads, null: false, default: 0
      t.bigint :input_tokens, null: false, default: 0
      t.bigint :output_tokens, null: false, default: 0
      t.decimal :cost_usd, precision: 14, scale: 8, null: false, default: 0
      t.integer :elapsed_ms
      t.string :model_id, null: false
      t.timestamps
    end
    add_index :field_swarm_searches, [ :account_id, :created_at ]
    add_check_constraint :field_swarm_searches, "status IN ('running', 'complete', 'failed')", name: "field_swarm_searches_status"

    # One reader call: one part of one item.
    create_table :field_swarm_reads do |t|
      t.references :field_swarm_search, null: false, foreign_key: { on_delete: :cascade }
      t.references :account, null: false, foreign_key: true
      t.string :item_kind, null: false
      t.bigint :item_id, null: false
      t.integer :part, null: false, default: 1
      t.integer :parts, null: false, default: 1
      t.integer :input_chars, null: false
      t.string :status, null: false
      t.string :verdict
      t.string :error
      t.bigint :input_tokens
      t.bigint :output_tokens
      t.decimal :cost_usd, precision: 14, scale: 8
      t.integer :latency_ms
      t.string :upstream_id
      # Sent, and no cost came back: it may have been billed.
      t.boolean :cost_uncertain, null: false, default: false
      t.timestamps
    end
    add_index :field_swarm_reads, [ :account_id, :created_at ]
    add_check_constraint :field_swarm_reads, "status IN ('read', 'failed', 'rate_limited', 'timed_out')", name: "field_swarm_reads_status"
  end

end
