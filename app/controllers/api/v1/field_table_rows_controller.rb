module Api
  module V1
    # Rows of one table. A write touches one row (or, for bulk, adds up to
    # Limits#bulk_rows as one all-or-nothing write).
    class FieldTableRowsController < BaseController

      include FieldTableApi

      MAX_PAGE = FieldTable::Limits::ROWS

      # where[key]=value (equality), sort=key or -key (or created), limit, offset.
      def index
        where = params[:where]
        where = where.respond_to?(:to_unsafe_h) ? where.to_unsafe_h : {}
        rows = field_table.query_rows(where: where, sort: params[:sort])
        total = rows.count
        limit = params[:limit].present? ? params[:limit].to_i.clamp(1, MAX_PAGE) : MAX_PAGE
        offset = [ params[:offset].to_i, 0 ].max
        render json: { rows: rows.limit(limit).offset(offset).map(&:as_api_json), total: total,
                       columns: field_table.columns }
      end

      def show
        render json: { row: row.as_api_json }
      end

      # data: { column => value }
      def create
        created = field_table.add_rows!([ data_param(params[:data]) ], by: current_api_editor).first
        render json: { row: created.as_api_json }, status: :created
      end

      # rows: [{ column => value }, ...]
      def bulk
        list = params[:rows]
        raise FieldTable::Refused, "rows must be a list of objects" unless list.is_a?(Array)

        limit = field_table.limits.bulk_rows
        raise FieldTable::Refused, "Send at most #{limit} rows at once (got #{list.size})" if list.size > limit

        created = field_table.add_rows!(list.map { |item| data_param(item) }, by: current_api_editor)
        render json: { rows: created.map(&:as_api_json) }, status: :created
      end

      # data: { column => value } (only these keys change; null clears),
      # lock_version: the row's version when read (optional; omitted = last write wins).
      def update
        updated = field_table.update_row!(row, data_param(params[:data]), by: current_api_editor,
          lock_version: lock_version_param)
        render json: { row: updated.as_api_json }
      end

      def destroy
        field_table.discard_row!(row, by: current_api_editor, lock_version: lock_version_param)
        head :no_content
      end

      private

      def row
        @row ||= field_table.live_rows.find(params[:id])
      end

    end
  end
end
