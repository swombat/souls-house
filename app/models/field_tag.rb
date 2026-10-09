# A tag in an account's Field: a name many items can carry ("life", "zar",
# "souls.house"). Tags are the account's, not any one item's, which is why
# changing a tag itself is a person's act (FieldTag#rename!, #discard_by!):
# it changes every item that carries it, including other people's.
#
# Names are folded so "Life", " life " and "#life" are one tag. Deleting a
# tag discards it: the row and its taggings stay, and every reader stops
# seeing it. Using the name again makes a new tag.
class FieldTag < ApplicationRecord

  include Discard::Model
  include ObfuscatesId

  class Conflict < StandardError

    attr_reader :existing

    def initialize(existing)
      @existing = existing
      super("A tag named #{existing.name} already exists")
    end

  end

  class Invalid < StandardError; end

  MAX_NAME_LENGTH = 50
  MAX_PER_ITEM = 32
  MAX_PER_ACCOUNT = 1_000

  belongs_to :account
  belongs_to :created_by, polymorphic: true, optional: true
  belongs_to :discarded_by, polymorphic: true, optional: true
  has_many :taggings, class_name: "FieldTagging", dependent: :destroy

  validates :name, presence: true, length: { maximum: MAX_NAME_LENGTH }
  validate :name_unique_among_kept

  before_validation { self.name = self.class.normalize(name) }

  scope :by_name, -> { order(:name) }

  # "  #Life  Story " -> "life story". Control characters become spaces.
  def self.normalize(name)
    name.to_s.unicode_normalize(:nfc).gsub(/[[:cntrl:]]/, " ").squish.delete_prefix("#").strip.downcase
  end

  # Normalised, de-duplicated names from what a caller sent, or Invalid.
  def self.normalize_list(names)
    list = Array(names)
    raise Invalid, "Tags must be a list of names" unless list.all? { |name| name.is_a?(String) }

    list.map { |name| normalize(name) }.reject(&:blank?).uniq.each do |name|
      raise Invalid, "Tag names can be at most #{MAX_NAME_LENGTH} characters (#{name.truncate(60)})" if name.length > MAX_NAME_LENGTH
    end
  end

  # A list of names exactly as a request sent it: nil when the key is absent,
  # otherwise an Array of Strings, or Invalid. Never coerces: a scalar, an
  # object, null or a mixed list is refused rather than read as "no tags",
  # because `tags` replaces the whole list and an empty one removes them all.
  def self.list_param(params, key)
    return nil unless params.key?(key)

    value = params[key]
    unless value.is_a?(Array) && value.all? { |name| name.is_a?(String) }
      raise Invalid, "#{key} must be a list of tag names, like [\"life\"]"
    end

    value
  end

  # The kept tag of this name in the account, made on first use.
  def self.named!(account, name, by:)
    name = normalize(name)
    existing = account.field_tags.kept.find_by(name: name)
    return existing if existing

    if account.field_tags.kept.count >= MAX_PER_ACCOUNT
      raise Invalid, "This Field already has #{MAX_PER_ACCOUNT} tags"
    end

    transaction(requires_new: true) { account.field_tags.create!(name: name, created_by: by) }
  rescue ActiveRecord::RecordNotUnique
    account.field_tags.kept.find_by!(name: name)
  end

  # Item counts for kept taggings on items that are still in the Field.
  def self.item_counts(account)
    FieldTagging.visible_in(account).group(:field_tag_id).count
  end

  # Rename, everywhere at once. Onto an existing name: Conflict, unless
  # merge, which moves this tag's items over to the other and discards this
  # one. Returns the tag that now carries the name.
  def rename!(new_name, by:, merge: false)
    account.with_lock do
      reload
      raise ActiveRecord::RecordNotFound if discarded?

      normalized = self.class.normalize(new_name)
      target = account.field_tags.kept.where.not(id: id).find_by(name: normalized)
      next tap { update!(name: normalized) } unless target
      raise Conflict, target unless merge

      taggings.kept.find_each do |tagging|
        if target.taggings.kept.exists?(taggable_type: tagging.taggable_type, taggable_id: tagging.taggable_id)
          tagging.update!(discarded_at: Time.current, discarded_by: by)
        else
          tagging.update!(field_tag: target)
        end
      end
      update!(discarded_at: Time.current, discarded_by: by)
      target
    end
  end

  def discard_by!(by)
    account.with_lock do
      reload
      update!(discarded_at: Time.current, discarded_by: by) unless discarded?
    end
  end

  private

  def name_unique_among_kept
    return if discarded? || name.blank?

    clash = FieldTag.kept.where(account_id: account_id, name: name).where.not(id: id)
    errors.add(:name, "is already a tag here") if clash.exists?
  end

end
