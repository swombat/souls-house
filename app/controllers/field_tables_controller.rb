# Tables in the Field: a list, and one page per table with an editable grid.
# The same FieldTable methods serve residents through /api/v1/field_tables.
class FieldTablesController < ApplicationController

  include FieldTablePages

  def index
    tables = current_account.field_tables.kept.by_name.includes(:updated_by)
    counts = FieldTableRow.kept.where(field_table_id: tables.map(&:id)).group(:field_table_id).count
    render inertia: "field/tables/index", props: {
      tables: tables.map { |table| summary_json(table, counts.fetch(table.id, 0)) },
      limits: FieldTable::Limits.for(current_account).as_json,
      account: current_account.as_json
    }
  end

  def show
    render inertia: "field/tables/show", props: {
      table: summary_json(field_table, field_table.live_rows.count),
      rows: field_table.live_rows.includes(:last_written_by).map(&:as_api_json),
      column_types: FieldTable::Column::TYPES,
      stones: field_table.reading_stones.includes(:stone_revisions).map { |stone| stone_json(stone) },
      limits: field_table.limits.as_json,
      account: current_account.as_json
    }
  end

  def create
    @field_table = FieldTable.create_in!(current_account, name: params[:name], by: Current.user,
      columns: [ { "key" => "name", "label" => "Name" } ])
    back_to_table
  end

  def update
    field_table.rename!(params[:name], by: Current.user)
    back_to_table
  end

  def destroy
    field_table.discard_by!(Current.user)
    redirect_to account_field_tables_path(current_account), notice: "#{field_table.name} deleted."
  end

  # Stops every revision of a public stone reading this table, at once.
  def detach_stone
    stone = field_table.reading_stones.find(params[:stone_id])
    field_table.detach_stone!(stone)
    redirect_to account_field_table_path(current_account, field_table), notice: "Detached. That stone no longer reads #{field_table.name}."
  end

  # A write link lets whoever holds it add rows to every table the stone
  # reads. Making one again replaces the key, so the old link stops working.
  def issue_write_link
    stone = field_table.reading_stones.find(params[:stone_id])
    stone.issue_write_key!
    redirect_to account_field_table_path(current_account, field_table), notice: "Write link made. Anyone holding it can add rows."
  end

  def revoke_write_link
    stone = field_table.reading_stones.find(params[:stone_id])
    stone.revoke_write_key!
    redirect_to account_field_table_path(current_account, field_table), notice: "Write link revoked. The stone is read-only again."
  end

  def export
    filename = "#{field_table.name.parameterize.presence || 'table'}.csv"
    send_data field_table.to_csv, filename: filename, type: "text/csv"
  end

  # A CSV file whose header names the columns (by key or label). Refused
  # whole on an unknown header, a bad value or the row limit.
  def import
    file = params[:file]
    raise FieldTable::Refused, "Choose a CSV file to import" unless file.respond_to?(:read)
    raise FieldTable::Refused, "That file is too large for a table" if file.size > 2.megabytes

    added = field_table.import_csv!(file.read.force_encoding(Encoding::UTF_8), by: Current.user)
    redirect_to account_field_table_path(current_account, field_table), notice: "Imported #{added.size} #{'row'.pluralize(added.size)}."
  end

  private

  def stone_json(stone)
    latest = stone.stone_revisions.max_by(&:number)
    { id: stone.to_param, title: latest&.title, public_url: stone.public_url, **stone.write_json }
  end

  def summary_json(table, row_count)
    {
      id: table.to_param,
      name: table.name,
      columns: table.columns,
      row_count: row_count,
      updated_at: table.updated_at.iso8601,
      updated_by: table.editor_name
    }
  end

end
