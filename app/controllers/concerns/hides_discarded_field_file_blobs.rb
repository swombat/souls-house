# A discarded Field file keeps its row and bytes, but signed blob URLs never
# expire, so a URL copied before the discard would keep serving it. Hide a
# blob whose every owner is a discarded FieldFile. A blob still attached to a
# kept FieldFile or to any other record stays reachable; undiscarding the file
# makes old URLs work again.
#
# Limit: a storage-service URL already handed out by the redirect before the
# discard lives until it expires (five minutes by default).
module HidesDiscardedFieldFileBlobs

  private

  def blob_scope
    field_attachments = ActiveStorage::Attachment.where(record_type: "FieldFile")
    reachable = ActiveStorage::Attachment.where.not(record_type: "FieldFile")
      .or(field_attachments.where(record_id: FieldFile.kept.select(:id)))
      .select(:blob_id)
    hidden = field_attachments
      .where(record_id: FieldFile.discarded.select(:id))
      .where.not(blob_id: reachable)
      .select(:blob_id)

    super.where.not(id: hidden)
  end

end
