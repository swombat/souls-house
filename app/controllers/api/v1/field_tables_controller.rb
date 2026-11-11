module Api
  module V1
    # Small tables in the key's home Field. Residents may create and change
    # tables (it is their Field too); a resident discards only tables it made.
    class FieldTablesController < BaseController

      include FieldTableApi

      def index
        tables = current_api_account.field_tables.kept.by_name
        render json: { field_tables: tables.map { |table| table_json(table) },
                       limits: FieldTable::Limits.for(current_api_account).as_json }
      end

      def show
        render json: { field_table: table_json(field_table, rows: field_table.live_rows) }
      end

      # name, columns: [{ key, label?, type? }] (types: text number date boolean link).
      def create
        columns = params[:columns]
        columns = columns.map { |c| c.respond_to?(:to_unsafe_h) ? c.to_unsafe_h : c } if columns.is_a?(Array)
        raise FieldTable::Refused, "columns must be a list" unless columns.nil? || columns.is_a?(Array)

        table = FieldTable.create_in!(current_api_account, name: params[:name], columns: columns || [], by: current_api_editor)
        render json: { field_table: table_json(table) }, status: :created
      end

      # Renames the table. Columns change through /columns.
      def update
        raise FieldTable::Refused, "Provide name" if params[:name].blank?

        field_table.rename!(params[:name], by: current_api_editor)
        render json: { field_table: table_json(field_table) }
      end

      def destroy
        if current_api_agent && field_table.created_by != current_api_agent
          return render json: { error: "Residents can delete only tables they made; a person can delete it from the Field" },
            status: :forbidden
        end

        field_table.discard_by!(current_api_editor)
        head :no_content
      end

    end
  end
end
