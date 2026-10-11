class AddPdfExtractionToFieldFiles < ActiveRecord::Migration[8.1]

  def change
    # A PDF's reading state (FieldFile::PdfExtraction): nil for files that
    # are not PDFs. pdf_coverage counts pages by state so lists need no join.
    add_column :field_files, :pdf_status, :string
    add_column :field_files, :pdf_status_reason, :string, limit: 500
    add_column :field_files, :pdf_page_count, :integer
    add_column :field_files, :pdf_coverage, :jsonb

    # One row per page read. native_text is the PDF's own text layer, never
    # anything a model wrote.
    create_table :field_file_pages do |t|
      t.references :field_file, null: false, foreign_key: true, index: false
      t.integer :page_number, null: false
      t.string :native_status, null: false
      t.text :native_text
      t.string :native_reason, limit: 500
      t.timestamps
    end
    add_index :field_file_pages, [ :field_file_id, :page_number ], unique: true
  end

end
