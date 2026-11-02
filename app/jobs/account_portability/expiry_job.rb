# Removes expired account archives, and uploads left behind by imports that
# were never confirmed (docs/features/account-portability.md).
class AccountPortability::ExpiryJob < ApplicationJob

  queue_as :default

  UNCONFIRMED_LIFETIME = 2.days

  def perform(now: Time.current)
    AccountExport.where(status: "ready").where(expires_at: ..now).find_each do |export|
      export.archive.purge
      export.update!(status: "expired")
    end
    AccountImport.where(status: %w[previewed invalid]).where(updated_at: ..(now - UNCONFIRMED_LIFETIME)).find_each do |import|
      import.upload.purge if import.upload.attached?
    end
    AccountImport.where(status: "failed").where(updated_at: ..(now - AccountExport::LIFETIME)).find_each do |import|
      import.upload.purge if import.upload.attached?
    end
  end

end
