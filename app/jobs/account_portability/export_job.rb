# Builds an account archive in the background (docs/features/account-portability.md).
class AccountPortability::ExportJob < ApplicationJob

  queue_as :default

  def perform(id)
    export = AccountExport.find_by(id: id)
    return unless export
    export.with_lock do
      return unless export.status.in?(%w[queued running])
      export.update!(status: "running", progress: { "step" => "starting" })
    end
    last = Time.at(0)
    progress = lambda do |step, done, total|
      next if Time.current - last < 2.seconds && done.positive?
      last = Time.current
      export.update_columns(progress: { "step" => step, "done" => done, "total" => total }, updated_at: Time.current)
    end
    Accounts::Portability::Export.call(export.account, exporter: export.user, conversations: export.include_conversations, progress:) do |path, manifest|
      File.open(path, "rb") do |io|
        export.archive.attach(io: io, filename: "souls-house-account-#{export.account.to_param}-#{Date.current.iso8601}.zip",
          content_type: "application/zip", identify: false)
      end
      summary = manifest.slice("export_id", "partial", "omitted").merge(
        "residents" => manifest["residents"].map { |r| r.slice("name", "status", "reason") }
      )
      export.update!(status: "ready", summary: summary, progress: { "step" => "done" }, finished_at: Time.current,
        expires_at: AccountExport::LIFETIME.from_now)
      AuditLog.create!(user: export.user, account: export.account, action: "export_account_archive", auditable: export,
        data: manifest.slice("export_id", "created_at", "partial").merge("conversations" => export.include_conversations,
          "residents_included" => manifest["residents"].count { |r| r["status"] == "included" },
          "residents_skipped" => manifest["residents"].count { |r| r["status"] == "skipped" }))
    end
  rescue Accounts::Portability::Error => error
    export&.update_columns(status: "failed", error: error.message.truncate(1000), finished_at: Time.current, updated_at: Time.current)
  rescue StandardError => error
    export&.update_columns(status: "failed", error: "Export failed (#{error.class.name.demodulize}). Nothing was changed in the account.",
      finished_at: Time.current, updated_at: Time.current)
    raise
  end

end
