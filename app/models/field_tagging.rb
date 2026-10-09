# One item carrying one tag, with who put it there. Taking a tag off an item
# discards the tagging (who and when stay on the row); putting it back makes
# a new one.
class FieldTagging < ApplicationRecord

  include Discard::Model

  TAGGABLE_TYPES = %w[FieldFile FieldRecording Whiteboard].freeze

  belongs_to :account
  belongs_to :field_tag
  belongs_to :taggable, polymorphic: true
  belongs_to :tagged_by, polymorphic: true, optional: true
  belongs_to :discarded_by, polymorphic: true, optional: true

  validates :taggable_type, inclusion: { in: TAGGABLE_TYPES }

  # Kept taggings of kept tags, on items still in the account's Field.
  def self.visible_in(account)
    kept.where(account_id: account.id)
      .where(field_tag_id: FieldTag.kept.where(account_id: account.id).select(:id))
      .where(<<~SQL.squish)
        (taggable_type = 'FieldFile' AND taggable_id IN (SELECT id FROM field_files WHERE discarded_at IS NULL))
        OR (taggable_type = 'FieldRecording' AND taggable_id IN (SELECT id FROM field_recordings WHERE discarded_at IS NULL))
        OR (taggable_type = 'Whiteboard' AND taggable_id IN (SELECT id FROM whiteboards WHERE deleted_at IS NULL))
      SQL
  end

  # Tag names for many items at once: { [type, id] => ["life", "zar"] }.
  def self.names_for(items)
    items = Array(items).compact
    return {} if items.empty?

    pairs = items.group_by { |item| item.class.base_class.name }
    scope = kept.joins(:field_tag).merge(FieldTag.kept)
    conditions = pairs.map { |type, list| sanitize_sql([ "(field_taggings.taggable_type = ? AND field_taggings.taggable_id IN (?))", type, list.map(&:id) ]) }
    scope.where(conditions.join(" OR "))
      .order("field_tags.name")
      .pluck(:taggable_type, :taggable_id, "field_tags.name")
      .each_with_object(Hash.new { |hash, key| hash[key] = [] }) { |(type, id, name), memo| memo[[ type, id ]] << name }
  end

end
