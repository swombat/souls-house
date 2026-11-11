# Shared by the Field table API controllers: the key's home account only (as
# for every Field endpoint), readable refusals, and one JSON shape per thing.
module FieldTableApi

  extend ActiveSupport::Concern

  included do
    include ApiHomeAccountOnly

    rescue_from FieldTable::Refused do |error|
      body = { error: error.message }
      body[:columns] = error.details[:columns] if error.details[:columns]
      render json: body, status: :unprocessable_entity
    end

    rescue_from FieldTable::Stale do |error|
      render json: { error: error.message, row: error.row.as_api_json }, status: :conflict
    end
  end

  private

  def field_table
    @field_table ||= current_api_account.field_tables.kept.find(params[:field_table_id] || params[:id])
  end

  def table_json(table, rows: nil)
    limits = table.limits
    json = {
      id: table.to_param,
      name: table.name,
      columns: table.columns,
      row_count: table.live_rows.count,
      limits: { rows: limits.rows_per_table, row_bytes: limits.row_bytes, columns: limits.columns },
      created_by: table.editor_name(table.created_by),
      updated_by: table.editor_name(table.updated_by),
      created_at: table.created_at.iso8601,
      updated_at: table.updated_at.iso8601
    }
    json[:rows] = rows.map(&:as_api_json) if rows
    json
  end

  # A plain Hash of column key => value from a JSON object parameter.
  def data_param(value)
    value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    raise FieldTable::Refused, "data must be an object of column => value" unless value.is_a?(Hash)

    value
  end

  def lock_version_param
    return nil unless params.key?(:lock_version)

    Integer(params[:lock_version].to_s, 10)
  rescue ArgumentError
    raise FieldTable::Refused, "lock_version must be an integer"
  end

end
