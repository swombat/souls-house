# One row of a FieldTable. Writes go through FieldTable (add_rows!,
# update_row!, discard_row!), which hold the table lock and check the data.
class FieldTableRow < ApplicationRecord

  include Discard::Model
  include ObfuscatesId

  belongs_to :field_table, inverse_of: :rows
  belongs_to :last_written_by, polymorphic: true, optional: true

  def writer_name
    field_table.editor_name(last_written_by)
  end

  def as_api_json
    {
      id: to_param,
      data: data,
      lock_version: lock_version,
      created_at: created_at.iso8601,
      updated_at: updated_at.iso8601,
      written_by: writer_name
    }
  end

end
