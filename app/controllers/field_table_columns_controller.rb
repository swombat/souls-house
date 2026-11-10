class FieldTableColumnsController < ApplicationController

  include FieldTablePages

  def create
    field_table.add_column!(params.permit(:key, :label, :type).to_h, by: Current.user)
    back_to_table
  end

  def update
    changes = params.permit(:new_key, :label, :type).to_h
    changes["key"] = changes.delete("new_key") if changes.key?("new_key")
    field_table.change_column!(params[:key], changes, by: Current.user)
    back_to_table
  end

  def destroy
    field_table.remove_column!(params[:key], by: Current.user)
    back_to_table
  end

end
