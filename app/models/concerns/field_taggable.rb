# Something in the Field that can carry tags: files, recordings, notes.
module FieldTaggable

  extend ActiveSupport::Concern

  included do
    has_many :field_taggings, as: :taggable, dependent: :destroy
    # The search vector is large (a whole transcript's lexemes) and only the
    # database reads it, so it never rides along on a record load.
    self.ignored_columns += [ "search_vector" ]
  end

  def tag_names
    field_taggings.kept.joins(:field_tag).merge(FieldTag.kept).order("field_tags.name").pluck("field_tags.name")
  end

  # Add and remove by name, or set the whole list. A name that isn't a tag
  # yet becomes one. People and residents may both do this; changing a tag
  # itself (rename, delete) is FieldTag's and is a person's act. Returns the
  # item's tag names afterwards. Raises FieldTag::Invalid.
  def change_tags!(by:, add: [], remove: [], set: nil)
    add = FieldTag.normalize_list(add)
    remove = FieldTag.normalize_list(remove)

    transaction do
      # The item's own row serialises concurrent changes to its tags.
      self.class.unscoped.where(id: id).lock.pluck(:id)
      current = tag_names

      unless set.nil?
        wanted = FieldTag.normalize_list(set)
        add = wanted - current
        remove = current - wanted
      end
      overlap = add & remove
      raise FieldTag::Invalid, "Can't add and remove the same tag (#{overlap.first})" if overlap.any?

      if (current - remove + add).uniq.size > FieldTag::MAX_PER_ITEM
        raise FieldTag::Invalid, "An item can carry at most #{FieldTag::MAX_PER_ITEM} tags"
      end

      if remove.any?
        field_taggings.kept.joins(:field_tag).merge(FieldTag.kept).where(field_tags: { name: remove }).find_each do |tagging|
          tagging.update!(discarded_at: Time.current, discarded_by: by)
        end
      end

      (add - current).each do |name|
        tag = FieldTag.named!(account, name, by: by)
        field_taggings.create!(account: account, field_tag: tag, tagged_by: by)
      end
    end

    tag_names
  end

end
