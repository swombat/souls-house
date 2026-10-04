class VisualTag < ApplicationRecord

  include Broadcastable
  include SyncAuthorizable

  ICON_OPTIONS = %w[
    ChatCircle Wrench MagnifyingGlass Sparkle Heart Palette BookOpen Compass Lifebuoy
    Lightbulb Flask Code MusicNote Camera Leaf Sun Moon Star Globe Calendar
    CheckCircle Flag Handshake House Briefcase GraduationCap Bookmark Lightning
  ].freeze
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
