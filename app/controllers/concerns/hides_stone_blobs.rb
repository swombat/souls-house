# Only the sandboxed content endpoint may serve a StoneRevision HTML blob.
# Block the generic signed blob and representation endpoints even if an ID leaks.
module HidesStoneBlobs

  private

  def blob_scope
    # purge_later detaches synchronously. Keep the marker on the blob itself so
    # withdrawal cannot reopen a generic URL while the purge job is queued.
    super
      .where.not(id: ActiveStorage::Attachment.where(record_type: "StoneRevision").select(:blob_id))
      .where("COALESCE(metadata::jsonb ->> 'stone_html', 'false') != 'true'")
  end

end
