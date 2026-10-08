# Signed blob and representation URLs never expire, so a URL issued before a
# message or Field file was discarded would keep delivering its retained bytes
# (issue #94, PR B; the Field, PR #184). Narrow ActiveStorage's own blob
# lookup with one reachability rule across every discardable owner type: a
# blob is hidden when it has at least one discarded owner and no live owner.
# A live owner is any attachment whose record is not discarded, of any type
# (a fork's copy, a kept Field file, an avatar). Restoring an owner makes the
# old URLs work again.
#
# Both discardable owner types share this one rule on purpose: two separate
# filters that each trusted the other type's attachments as live let a
# discarded message and a discarded Field file keep each other's blob served.
#
# Limit: a storage-service URL already handed out by the redirect before the
# discard lives until it expires (ActiveStorage's service_urls_expire_in,
# five minutes by default). That is bounded; the signed URL is not.
module HidesDiscardedBlobs

  DISCARDABLE_OWNERS = {
    "Message" => -> { Message },
    "FieldFile" => -> { FieldFile },
    "FieldRecording" => -> { FieldRecording }
  }.freeze

  private

  def blob_scope
    attachments = ActiveStorage::Attachment.all
    discarded_owner = DISCARDABLE_OWNERS.map do |type, model|
      attachments.where(record_type: type, record_id: model.call.discarded.select(:id))
    end.reduce(:or)

    live = attachments.where.not(id: discarded_owner.select(:id)).select(:blob_id)
    hidden = discarded_owner.where.not(blob_id: live).select(:blob_id)

    super.where.not(id: hidden)
  end

end
