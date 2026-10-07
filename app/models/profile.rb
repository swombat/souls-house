class Profile < ApplicationRecord

  include JsonAttributes

  belongs_to :user

  # Avatar attachment - moved from User
  has_one_attached :avatar do |attachable|
    attachable.variant :thumb, resize_to_fill: [ 100, 100 ]
    attachable.variant :medium, resize_to_fill: [ 300, 300 ]
  end

  # Normalization
  normalizes :first_name, with: ->(name) { name&.strip }
  normalizes :last_name, with: ->(name) { name&.strip }

  VALID_CHAT_COLOURS = %w[
    slate gray zinc neutral stone
    red orange amber yellow lime green
    emerald teal cyan sky blue indigo
    violet purple fuchsia pink rose
  ].freeze

  # Validations
  validates :theme, inclusion: { in: %w[light dark system] }, allow_nil: true
  validates :timezone, inclusion: { in: ActiveSupport::TimeZone.all.map(&:name) }, allow_blank: true
  validates :chat_colour, inclusion: { in: VALID_CHAT_COLOURS }, allow_nil: true
  # One hue tints the whole neutral palette; lightness and intensity are fixed in CSS so no hue can be garish.
  validates :theme_hue, numericality: { only_integer: true, in: 0..359 }, allow_nil: true
  validates_presence_of :first_name, :last_name, if: -> { user&.confirmed? }

  # Avatar validations
  validates :avatar, content_type: [ "image/png", "image/jpeg", "image/gif", "image/webp" ],
                     size: { less_than: 5.megabytes }

  # Callbacks
  after_initialize :set_default_theme, if: :new_record?

  # JSON attributes to include theme preferences
  def preferences
    { "theme" => theme, "theme_hue" => theme_hue }.compact
  end

  def full_name
    "#{first_name} #{last_name}".strip.presence
  end

  def avatar_url
    return nil unless avatar.attached?
    return nil unless avatar_file_exists?

    if avatar.variable?
      Rails.application.routes.url_helpers.rails_representation_url(
        avatar.variant(resize_to_fill: [ 200, 200 ]),
        only_path: true
      )
    else
      Rails.application.routes.url_helpers.rails_blob_url(avatar, only_path: true)
    end
  end

  def avatar_file_exists?
    return false unless avatar.attached?
    Rails.cache.fetch("avatar_exists/#{avatar.blob.key}", expires_in: 5.minutes) do
      avatar.blob.service.exist?(avatar.blob.key)
    end
  rescue StandardError
    false
  end

  def initials
    return "?" unless full_name.present?
    full_name.split.map(&:first).first(2).join.upcase
  end

  private

  def set_default_theme
    self.theme ||= "system"
  end

end
