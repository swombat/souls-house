# Validates an uploaded account archive and records its preview, naming the
# SHA-256 of exactly the bytes checked (docs/features/account-portability.md).
class AccountPortability::ValidateJob < ApplicationJob

  queue_as :default

  def perform(id)
    import = AccountImport.find_by(id: id)
    return unless import
    import.with_lock do
      return unless import.status.in?(%w[uploaded validating])
      import.update!(status: "validating")
    end
    raise Accounts::Portability::Error, "The upload is missing" unless import.upload.attached?
    import.upload.blob.open do |file|
      Accounts::Portability::Archive.with_file(file) do |archive|
        preview = archive.preview
        preview[:same_installation] = archive.manifest["source_installation"] == Digest::SHA256.hexdigest(Agents::Config.internal_url)
        preview[:destination_refusal] = Accounts::Portability::Import.destination_refusal(import.account)
        import.update!(status: "previewed", archive_sha256: archive.sha256, preview: preview, error: nil)
      end
    end
  rescue Accounts::Portability::Error => error
    import&.update_columns(status: "invalid", error: error.message.truncate(1000), updated_at: Time.current)
    import&.upload&.purge_later
  rescue StandardError => error
    import&.update_columns(status: "invalid", error: "The archive could not be read (#{error.class.name.demodulize})", updated_at: Time.current)
    import&.upload&.purge_later
    raise
  end

end
