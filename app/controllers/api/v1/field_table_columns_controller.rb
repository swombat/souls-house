module Api
  module V1
    # One call per column change: add, change (key, label or type), remove.
    class FieldTableColumnsController < BaseController

      include FieldTableApi

      def create
        field_table.add_column!(params.permit(:key, :label, :type).to_h, by: current_api_editor)
        render json: { field_table: table_json(field_table) }, status: :created
      end

      def update
        changes = params.permit(:new_key, :label, :type).to_h
        changes["key"] = changes.delete("new_key") if changes.key?("new_key")
        raise FieldTable::Refused, "Provide new_key, label or type" if changes.empty?

        field_table.change_column!(params[:key], changes, by: current_api_editor)
        render json: { field_table: table_json(field_table) }
      end

      def destroy
        field_table.remove_column!(params[:key], by: current_api_editor)
        render json: { field_table: table_json(field_table) }
      end

    end
  end
end
