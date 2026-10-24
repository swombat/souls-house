# Only the sandboxed content endpoint may serve a StoneRevision HTML blob.
# Block the generic signed blob and representation endpoints even if an ID leaks.
module HidesStoneBlobs

  private

  def blob_scope
    # Retained HTML must never bypass sandboxed delivery, including a blob
    # whose attachment association was lost by older withdrawal behavior.
    super
      .where.not(id: ActiveStorage::Attachment.where(record_type: "StoneRevision").select(:blob_id))
      .where("COALESCE(metadata::jsonb ->> 'stone_html', 'false') != 'true'")
  end

end
