class VisualTag < ApplicationRecord

  include Broadcastable
  include SyncAuthorizable

  ICON_OPTIONS = JSON.parse(Rails.root.join("config/visual_tag_icons.json").read).map(&:freeze).freeze
  COLOUR_OPTIONS = %w[slate blue teal violet rose amber indigo green orange red yellow cyan pink].freeze
  DEFAULTS = [
    [ "Conversation", "ChatCircle", "slate" ],
    [ "Building", "Wrench", "blue" ],
    [ "Research", "MagnifyingGlass", "teal" ],
    [ "Reflection", "Sparkle", "violet" ],
    [ "Care", "Heart", "rose" ],
    [ "Creative", "Palette", "amber" ],
    [ "Reading", "BookOpen", "indigo" ],
    [ "Plans", "Compass", "green" ],
    [ "Help", "Lifebuoy", "orange" ]
  ].map(&:freeze).freeze

  belongs_to :account
  has_many :chats
  broadcasts_to :account

  validates :label, presence: true, length: { maximum: 80 },
    format: { without: /\0/, message: "must not contain NUL" }
  validates :icon, inclusion: { in: ICON_OPTIONS }
  validates :colour, inclusion: { in: COLOUR_OPTIONS }
  validate :account_cannot_change, on: :update
  before_validation -> { self.label = label.strip if label.is_a?(String) }
  before_destroy :clear_chat_selections

  scope :palette_order, -> { order(:id) }

  # Browser-only account aggregate. Keep as_json and the resident API palette
  # presentation-only: guests must not learn usage in rooms they cannot see.
  # Archiving preserves a selection; only discarded conversations stop counting.
  def self.palette_with_usage_for(account)
    counts = account.chats.kept.where.not(visual_tag_id: nil).group(:visual_tag_id).count
    account.visual_tags.map do |tag|
      tag.as_json.merge("conversation_count" => counts.fetch(tag.id, 0))
    end.sort_by do |tag|
      [ -tag["conversation_count"], tag["label"].downcase, tag["label"], tag["id"] ]
    end
  end

  # Public writes accept opaque IDs only, not database IDs or coercible values.
  def self.resolve_for(account, public_id)
    return if public_id.nil?

    unless public_id.is_a?(String) && public_id.match?(/\A[a-zA-Z]+\z/) &&
        (id = decode_id(public_id)) && encode_id(id) == public_id
      raise ActiveRecord::RecordNotFound
    end

    account.visual_tags.find(id)
  end

  def as_json(_options = nil)
    { "id" => to_param, "label" => label, "icon" => icon, "colour" => colour }
  end

  private

  def account_cannot_change
    errors.add(:account, "cannot be changed") if will_save_change_to_account_id?
  end

  def clear_chat_selections
    chats.find_each { |chat| chat.update!(visual_tag: nil) }
  end

end
