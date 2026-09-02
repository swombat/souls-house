class Admin::AuditLogsController < ApplicationController

  before_action :require_site_admin

  def index
    # Controller orchestrates scope chaining
    logs = AuditLog.all
    logs = apply_filters(logs)
    logs = logs.includes(:user, :account).recent

    # Pagy handles pagination elegantly
    @pagy, @audit_logs = pagy(:offset, logs, limit: params[:per_page] || 10)

    # Load selected log if requested
    @selected_log = AuditLog.find(params[:log_id]) if params[:log_id]

    render inertia: "admin/audit-logs", props: audit_logs_props
  end

  private

  def apply_filters(scope)
    filters = processed_filters

    # Chain scopes based on provided filters
    scope = scope.by_user(filters[:user_id]) if filters[:user_id].present?
    scope = scope.by_account(filters[:account_id]) if filters[:account_id].present?
    scope = scope.by_action(filters[:audit_action]) if filters[:audit_action].present?
    scope = scope.by_type(filters[:auditable_type]) if filters[:auditable_type].present?
    scope = scope.date_from(filters[:date_from]) if filters[:date_from].present?
    scope = scope.date_to(filters[:date_to]) if filters[:date_to].present?

    scope
  end

  def audit_logs_props
    {
      audit_logs: @audit_logs.map(&:as_json),
      selected_log: @selected_log&.as_json(
        include: [ :user, :account, :auditable ]
      ),
      pagination: pagy_to_hash(@pagy),
      filters: filter_options,
      current_filters: filter_params.to_h.transform_keys { |key|
        # Return filter_account_id to frontend, not account_id
        key.to_s
      }
    }
  end

  def filter_options
    {
      users: User.all.order(:email_address).map(&:as_json),
      accounts: Account.all.order(:name).map(&:as_json),
      actions: AuditLog.available_actions,
      types: AuditLog.available_types
    }
  end

  def processed_filters
    # Pre-process filters to convert comma-separated strings to arrays
    processed_filters = filter_params.dup
    if processed_filters[:user_id].is_a?(String)
      # Handle both numeric and obfuscated IDs
      decoded = User.decode_ids_from_string(processed_filters[:user_id])
      # Ensure we always get a consistent type (integer)
      processed_filters[:user_id] = decoded.is_a?(String) ? decoded.to_i : decoded
    end
    if processed_filters[:filter_account_id].is_a?(String)
      # Handle both numeric and obfuscated IDs
      decoded = Account.decode_ids_from_string(processed_filters[:filter_account_id])
      # Ensure we always get a consistent type (integer)
      # Note: AuditLog.filtered expects :account_id, not :filter_account_id
      processed_filters[:account_id] = decoded.is_a?(String) ? decoded.to_i : decoded
      processed_filters.delete(:filter_account_id)
    end
    [ :audit_action, :auditable_type ].each do |key|
      if processed_filters[key].is_a?(String) && processed_filters[key].include?(",")
        processed_filters[key] = processed_filters[key].split(",").map(&:strip)
      end
    end
    processed_filters
  end

  def filter_params
    # NOTE: Exclude :action to avoid conflict with Rails controller action parameter
    # NOTE: Use filter_account_id instead of account_id to avoid conflict with AccountScoping
    params.permit(:user_id, :filter_account_id, :audit_action, :auditable_type,
                  :date_from, :date_to, :page, :per_page, :log_id)
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
