class AddFieldPdfOcr < ActiveRecord::Migration[8.1]

  def change
    # A page's model transcription, kept apart from its own text layer
    # (native_*). model_status: text, empty, failed or skipped; nil when the
    # page was never a candidate.
    add_column :field_file_pages, :model_status, :string
    add_column :field_file_pages, :model_text, :text
    add_column :field_file_pages, :model_reason, :string, limit: 500
    add_column :field_file_pages, :model_id, :string
    # Whether pdfimages found a picture on the page (nil: not known). A page
    # with little text of its own is transcribed only if it has one.
    add_column :field_file_pages, :has_images, :boolean

    # House switch and ceiling for Field OCR (off by default). Files brought
    # in before field_ocr_enabled_at are never sent.
    add_column :settings, :field_ocr_enabled, :boolean, default: false, null: false
    add_column :settings, :field_ocr_enabled_at, :datetime
    add_column :settings, :field_ocr_daily_usd_ceiling, :decimal, precision: 10, scale: 4, default: "1.0", null: false

    # One row per paid page call: reserved before the call (a conservative
    # charge), settled after with what the call cost. Failed and uncertain
    # calls keep their charge, so they count against the ceiling.
    create_table :field_ocr_calls do |t|
      t.references :account, null: false, foreign_key: true
      t.references :field_file, null: false, foreign_key: true, index: false
      t.integer :page_number, null: false
      t.date :day, null: false
      t.string :status, null: false, default: "reserved"
      t.decimal :charge_usd, precision: 14, scale: 8, null: false
      t.string :model_id, null: false
      t.string :upstream_id
      t.timestamps
    end
    add_index :field_ocr_calls, :day
    add_index :field_ocr_calls, [ :field_file_id, :page_number ]
    add_check_constraint :field_ocr_calls, "charge_usd >= 0", name: "field_ocr_calls_nonnegative_charge"
    add_check_constraint :field_ocr_calls, "status IN ('reserved', 'settled', 'failed', 'uncertain')", name: "field_ocr_calls_status"
  end

end
