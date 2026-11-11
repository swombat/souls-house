class FieldTableRowsController < ApplicationController

  include FieldTablePages

  def create
    field_table.add_rows!([ data_param ], by: Current.user)
    back_to_table
  end

  def update
    row = field_table.live_rows.find(params[:id])
    field_table.update_row!(row, data_param, by: Current.user, lock_version: lock_version_param)
    back_to_table
  end

  def destroy
    row = field_table.live_rows.find(params[:id])
    field_table.discard_row!(row, by: Current.user)
    back_to_table
  end

end
