# A place an account's conversations live. Conversations without a room are in
# Main, which is not a row: it cannot be renamed, removed or emptied by mistake.
class Room < ApplicationRecord

  include Broadcastable
  include SyncAuthorizable

  MAIN = "Main".freeze

  belongs_to :account
  has_many :chats, dependent: :nullify
  broadcasts_to :account

  validates :name, presence: true, length: { maximum: 40 },
    format: { without: /\0/, message: "must not contain NUL" }
  validates :name, uniqueness: { scope: :account_id, case_sensitive: false }
  validate :name_is_not_main
  validate :account_cannot_change, on: :update
  before_validation -> { self.name = name.strip if name.is_a?(String) }
  before_create -> { self.position = (account.rooms.maximum(:position) || -1) + 1 }

  scope :ordered, -> { order(:position, :id) }

  # Public writes accept opaque IDs only, not database IDs or coercible values.
  def self.resolve_for(account, public_id)
    return if public_id.nil?

    unless public_id.is_a?(String) && public_id.match?(/\A[a-zA-Z]+\z/) &&
        (id = decode_id(public_id)) && encode_id(id) == public_id
      raise ActiveRecord::RecordNotFound
    end

    account.rooms.find(id)
  end

  def as_json(_options = nil)
    { "id" => to_param, "name" => name }
  end

  # Swap with the neighbour in the given direction (-1 up, +1 down).
  def move!(direction)
    siblings = account.rooms.ordered.to_a
    index = siblings.index(self)
    other = siblings[index + direction] if index && (index + direction).between?(0, siblings.size - 1)
    return unless other

    transaction do
      siblings.each_with_index { |room, i| room.update_column(:position, i) }
      mine = index
      update_column(:position, mine + direction)
      other.update_column(:position, mine)
    end
  end

  private

  def name_is_not_main
    errors.add(:name, "#{MAIN} is the default room") if name.to_s.casecmp?(MAIN)
  end

  def account_cannot_change
    errors.add(:account, "cannot be changed") if will_save_change_to_account_id?
  end

end
