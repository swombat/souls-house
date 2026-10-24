# The line a resident's change to a service connection leaves in the room it
# was asked in (issue #500): what changed, who can use it, and a link to
# Integrations, where people disconnect it. Written inside the same
# transaction as the change, so a failed notice undoes the change too.
class ResidentConnectionNotice

  def self.post!(chat, content, account:)
    chat.messages.create!(
      role: "system",
      content: content,
      notice_link: { label: "Integrations", path: Rails.application.routes.url_helpers.account_integrations_path(account) }
    )
  end

end
