# Signed blob and representation URLs never expire, so a URL issued before a
# message was discarded would keep delivering its retained files (issue #94,
# PR B). Narrow ActiveStorage's own blob lookup: a blob whose every owner is
# a discarded message resolves to 404. A blob still attached to a kept message
# (a fork's copy) or to some other record stays reachable. Restoring the
# message makes the old URLs work again.
#
# Limit: a storage-service URL already handed out by the redirect before the
# discard lives until it expires (ActiveStorage's service_urls_expire_in,
# five minutes by default). That is bounded; the signed URL is not.
module HidesDiscardedMessageBlobs

  private

  def blob_scope
    message_attachments = ActiveStorage::Attachment.where(record_type: "Message")
    reachable = ActiveStorage::Attachment.where.not(record_type: "Message")
      .or(message_attachments.where(record_id: Message.kept.select(:id)))
      .select(:blob_id)
    hidden = message_attachments
      .where(record_id: Message.discarded.select(:id))
      .where.not(blob_id: reachable)
      .select(:blob_id)

    super.where.not(id: hidden)
  end

end
