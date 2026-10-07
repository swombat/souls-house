# A saved past state of a versioned item. PaperTrail writes one row per change,
# holding the item as it stood *before* that change (object) and the diff
# (object_changes). The class exists so version ids are obfuscated like every
# other id we expose, and so the editor stored in whodunnit can be resolved.
class ItemVersion < PaperTrail::Version

  include ObfuscatesId

  self.table_name = "versions"

  WHODUNNIT_TYPES = %w[User Agent].freeze

  def self.whodunnit_for(editor)
    return nil unless editor && WHODUNNIT_TYPES.include?(editor.class.name)

    "#{editor.class.name}:#{editor.id}"
  end

  # The person or resident who made this change, or nil if it was made outside
  # a request (console, a job) or the editor has since been deleted.
  def changed_by
    type, id = whodunnit.to_s.split(":", 2)
    return nil unless WHODUNNIT_TYPES.include?(type) && id.to_s.match?(/\A\d+\z/)

    type.constantize.find_by(id: id)
  end

end
