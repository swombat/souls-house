# Imports a previewed, confirmed account archive (docs/features/account-portability.md).
# Safe to run again after a failure: the import's ledger skips what exists.
class AccountPortability::ImportJob < ApplicationJob

  queue_as :default

  def perform(id)
    import = AccountImport.find_by(id: id)
    return unless import&.status == "importing"
    raise Accounts::Portability::Error, "The upload is missing" unless import.upload.attached?
    summary = nil
    import.upload.blob.open do |file|
      Accounts::Portability::Archive.with_file(file) do |archive|
        summary = Accounts::Portability::Import.call(archive, import: import)
      end
    end
    import.update!(status: "imported", finished_at: Time.current, error: nil)
    AuditLog.create!(user: import.user, account: import.account, action: "import_account_archive", auditable: import,
      data: { "export_id" => import.preview["export_id"], "archive_sha256" => import.archive_sha256,
              "residents" => summary["residents"], "conversations" => summary["conversations"] })
    import.upload.purge_later
  rescue Accounts::Portability::Error => error
    import&.update_columns(status: "failed", error: error.message.truncate(1000), finished_at: Time.current, updated_at: Time.current)
  rescue StandardError => error
    import&.update_columns(status: "failed", error: "Import stopped (#{error.class.name.demodulize}). What was created is kept; retrying continues from there.",
      finished_at: Time.current, updated_at: Time.current)
    raise
  end

end
