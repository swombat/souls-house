# Uploads and confirms an account import (docs/features/account-portability.md).
# Confirming names the SHA-256 shown in the preview; the job imports only
# those bytes.
class Accounts::AccountImportsController < ApplicationController

  include Accounts::PortabilityPrivacy

  before_action :require_account_owner!

  def create
    upload = params[:archive]
    return back_with("Choose an account archive (.zip) to upload.") unless upload.respond_to?(:read) && upload.respond_to?(:size)
    return back_with("That file is larger than the account archive limit.") if upload.size > Accounts::Portability::Archive::MAX_COMPRESSED
    if (refusal = Accounts::Portability::Import.destination_refusal(current_account))
      return back_with(refusal)
    end
    if current_account.account_imports.where(status: %w[uploaded validating importing]).exists?
      return back_with("An import is already in progress here.")
    end
    import = current_account.account_imports.create!(user: Current.user)
    import.upload.attach(io: upload, filename: "account-import-#{import.to_param}.zip", content_type: "application/zip", identify: false)
    AccountPortability::ValidateJob.perform_later(import.id)
    redirect_to account_portability_path(current_account), status: :see_other, notice: "Uploaded. Checking the archive before anything is created."
  end

  def confirm
    import = current_account.account_imports.find(params[:id])
    started = import.with_lock do
      next "This import cannot be started now." unless import.status.in?(%w[previewed failed]) && import.upload.attached?
      next "The archive changed since its preview. Upload it again." unless params[:sha256].to_s == import.archive_sha256.to_s && import.archive_sha256.present?
      next "Confirm that this makes a copy and that nothing runs until you start it." unless params[:confirmed].to_s == "true"
      if (refusal = Accounts::Portability::Import.destination_refusal(current_account, import: import))
        next refusal
      end
      import.update!(status: "importing", confirmed_at: import.confirmed_at || Time.current, error: nil)
      true
    end
    return back_with(started) unless started == true
    AccountPortability::ImportJob.perform_later(import.id)
    redirect_to account_portability_path(current_account), status: :see_other, notice: "Import started."
  end

  private

  def back_with(message)
    redirect_to account_portability_path(current_account), status: :see_other, alert: message
  end

end
