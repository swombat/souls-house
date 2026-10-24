# Older withdrawal code detached HTML then queued this generic job. Removing
# that enqueue alone would still let a pre-release job destroy retained source.
# Only the explicitly authorised permanent-erasure process may purge it.
module RetainsStoneHtml

  def perform(blob)
    return if ActiveModel::Type::Boolean.new.cast(blob.metadata["stone_html"])

    super
  end

end
