# Imports a previewed, confirmed account archive (docs/features/account-portability.md).
# Safe to run again after a failure: the import's ledger skips what exists.
class AccountPortability::ImportJob < ApplicationJob

  queue_as :default

  RELOCK_WAIT = 30.seconds

  def perform(id)
    import = AccountImport.find_by(id: id)
    return unless import&.status == "importing"
    # One run per account at a time: a second worker for this import (or any
    # other import here) waits rather than creating alongside it.
    Accounts::Portability::Import.with_account_lock(import.account) do |held|
      unless held
        self.class.set(wait: RELOCK_WAIT).perform_later(id)
        next
      end
      import.reload
      next unless import.status == "importing"
      run(import)
    end
  rescue Accounts::Portability::Error => error
    import&.update_columns(status: "failed", error: error.message.truncate(1000), finished_at: Time.current, updated_at: Time.current)
  rescue StandardError => error
    import&.update_columns(status: "failed", error: "Import stopped (#{error.class.name.demodulize}). What was created is kept; retrying continues from there.",
      finished_at: Time.current, updated_at: Time.current)
    raise
  end

  private

  def run(import)
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
    # Kept while anything can still be retried.
    import.upload.purge_later if summary["failures"].empty?
  end

end
