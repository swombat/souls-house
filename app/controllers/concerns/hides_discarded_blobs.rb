# Signed blob and representation URLs never expire, so a URL issued before a
# message, its parent chat, or a Field file was discarded would keep delivering
# its retained bytes (issue #94, PR B; the Field, PR #184). Narrow ActiveStorage's
# own blob lookup with one reachability rule across every discardable owner type:
# a blob is hidden when it has at least one discarded owner and no live owner.
# Messages are hidden if either their own row or parent chat is discarded; other
# discardable types use their own state. A live owner can be a kept message in a
# kept chat, a kept Field file, or a non-discardable record such as an avatar.
# Restoring an owner makes old URLs work again.
#
# All discardable owner types share this one rule on purpose: separate filters
# that each trusted the other type's attachments as live could let two discarded
# owners keep each other's blob served.
#
# Retained history attachments (a removed or replaced avatar, a resident's
# picture, or a logo, see
# RetainsReplacedAttachment) count as hidden too: their owner is live, but the
# image is no longer its current one. A blob still attached somewhere live
# stays served.
#
# Limit: a storage-service URL already handed out by the redirect before the
# discard lives until it expires (ActiveStorage's service_urls_expire_in,
# five minutes by default). That is bounded; the signed URL is not.
module HidesDiscardedBlobs

  DISCARDED_OWNER_RECORDS = {
    "Message" => -> {
      Message.with_discarded
        .joins(:chat)
        .where("messages.discarded_at IS NOT NULL OR chats.discarded_at IS NOT NULL")
    },
    "FieldFile" => -> { FieldFile.discarded },
    "FieldRecording" => -> { FieldRecording.discarded },
    "FieldSong" => -> { FieldSong.discarded }
  }.freeze

  RETIRED_ATTACHMENT_NAMES = {
    "Profile" => "retired_avatars",
    "Agent" => "retired_avatars",
    "Setting" => "retired_logos"
  }.freeze

  private

  def blob_scope
    attachments = ActiveStorage::Attachment.all
    discarded_owner = DISCARDED_OWNER_RECORDS.map do |type, records|
      attachments.where(record_type: type, record_id: records.call.select(:id))
    end
    retired = RETIRED_ATTACHMENT_NAMES.map { |type, name| attachments.where(record_type: type, name:) }
    hidden_owner = (discarded_owner + retired).reduce(:or)

    live = attachments.where.not(id: hidden_owner.select(:id)).select(:blob_id)
    hidden = hidden_owner.where.not(blob_id: live).select(:blob_id)

    super.where.not(id: hidden)
  end

end
