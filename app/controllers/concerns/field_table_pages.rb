# Shared by the Field table pages: the table in this account, and refusals
# shown on the page they came from (the grid reads errors.table).
module FieldTablePages

  extend ActiveSupport::Concern

  included do
    require_feature_enabled :agents

    rescue_from FieldTable::Refused do |error|
      back_with_error(error.message)
    end

    rescue_from FieldTable::Stale do |error|
      back_with_error("#{error.message}. The grid now shows the current row; make your change again if it still applies.")
    end
  end

  private

  def field_table
    @field_table ||= current_account.field_tables.kept.find(params[:field_table_id] || params[:id])
  end

  def back_with_error(message)
    target = @field_table&.persisted? && !@field_table.discarded? ? account_field_table_path(current_account, @field_table) : account_field_tables_path(current_account)
    redirect_to target, inertia: { errors: { table: message } }
  end

  def back_to_table
    redirect_to account_field_table_path(current_account, field_table)
  end

  def lock_version_param
    return nil if params[:lock_version].blank?

    Integer(params[:lock_version].to_s, 10)
  rescue ArgumentError
    raise FieldTable::Refused, "lock_version must be an integer"
  end

  def data_param
    value = params[:data]
    value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    raise FieldTable::Refused, "data must be an object of column => value" unless value.is_a?(Hash)

    value
  end

end
