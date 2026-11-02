# Starts an account export and serves its archive (docs/features/account-portability.md).
class Accounts::AccountExportsController < ApplicationController

  include Accounts::PortabilityPrivacy
  include ActiveStorage::Streaming

  before_action :require_account_owner!

  def create
    if current_account.account_exports.where(status: %w[queued running]).exists?
      return redirect_to account_portability_path(current_account), status: :see_other, alert: "An export is already being made."
    end
    export = current_account.account_exports.create!(user: Current.user, include_conversations: params[:include_conversations].to_s == "true")
    AccountPortability::ExportJob.perform_later(export.id)
    redirect_to account_portability_path(current_account), status: :see_other,
      notice: "Export started. Running residents are skipped, never stopped; the result says which."
  end

  def download
    export = current_account.account_exports.find(params[:id])
    raise ActiveRecord::RecordNotFound unless export.downloadable?
    AuditLog.create!(user: Current.user, account: current_account, action: "download_account_archive", auditable: export,
      data: { "export_id" => export.summary["export_id"] })
    response.headers["Content-Type"] = "application/zip"
    response.headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(disposition: "attachment", filename: export.archive.filename.to_s)
    send_blob_stream(export.archive.blob, disposition: :attachment)
  end

end
