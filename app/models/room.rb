# A place an account's conversations live. Conversations without a room are in
# Main, which is not a row: it cannot be removed or emptied by mistake. Its name
# and description are account settings (Account#main_room_label).
class Room < ApplicationRecord

  include Broadcastable
  include SyncAuthorizable

  MAIN = "Main".freeze

  belongs_to :account
  has_many :chats
  # One by one, not dependent: :nullify, so each move refreshes reply attention.
  before_destroy :move_chats_to_main
  broadcasts_to :account

  validates :name, presence: true, length: { maximum: 40 },
    format: { without: /\0/, message: "must not contain NUL" }
  validates :name, uniqueness: { scope: :account_id, case_sensitive: false }
  # "Use this room when…": a guideline for residents, not an instruction.
  validates :description, length: { maximum: 280 },
    format: { without: /\0/, message: "must not contain NUL" }
  validate :name_is_not_main
  validate :account_cannot_change, on: :update
  before_validation -> {
    self.name = name.strip if name.is_a?(String)
    self.description = description.strip.presence if description.is_a?(String)
  }
  before_create -> { self.position = (account.rooms.maximum(:position) || -1) + 1 }
  after_commit :broadcast_navigation

  scope :ordered, -> { order(:position, :id) }
  # Archived rooms keep their conversations, readable where they are, but are
  # no longer a place to put one: not in the switcher, the pickers, a rhythm's
  # rooms, or the directory residents choose from.
  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  validate :can_be_archived, if: -> { will_save_change_to_archived_at? && archived_at.present? }

  def archived? = archived_at.present?

  def archive!
    return if archived?

    update!(archived_at: Time.current)
  rescue ActiveRecord::RecordInvalid
    restore_attributes([ :archived_at ]) # a refused archive leaves the room active
    raise
  end

  def unarchive!
    update!(archived_at: nil) if archived?
  end

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
    json = { "id" => to_param, "name" => name }
    json["archived"] = true if archived?
    json
  end

  # The room as a place to choose, with what it is for. Main has no row, so
  # callers listing destinations put Account#main_room_json first.
  def directory_json
    as_json.merge("description" => description)
  end

  # Swap with the neighbour in the given direction (-1 up, +1 down).
  def move!(direction)
    # Among the rooms the list shows: an archived room is not a neighbour.
    siblings = account.rooms.ordered.to_a.select { |room| room.archived? == archived? }
    index = siblings.index(self)
    other = siblings[index + direction] if index && (index + direction).between?(0, siblings.size - 1)
    return unless other

    transaction do |transaction|
      siblings.each_with_index { |room, i| room.update_column(:position, i) }
      mine = index
      update_column(:position, mine + direction)
      other.update_column(:position, mine)
      # These position writes bypass model callbacks. Defer the single marker
      # to the outer commit too, so a rolled-back move never reaches the UI.
      transaction.after_commit { broadcast_navigation }
    end
  end

  private

  def broadcast_navigation
    return if skip_broadcast

    ActionCable.server.broadcast("RoomNavigation:#{account.to_param}", { action: "refresh" })
  end

  def move_chats_to_main
    account.chats.with_discarded.where(room_id: id).find_each { |chat| chat.room = nil; chat.save!(validate: false) }
  end

  # Archiving must not leave something pointing new conversations here.
  def can_be_archived
    if account&.resident_room_id == id
      errors.add(:base, "#{name} is the default room for residents; choose another default first")
    end
    commitments = Commitment.scheduled.where(account_id: account_id, room_id: id, destination: "new_conversation").count
    if commitments.positive?
      errors.add(:base, "#{commitments == 1 ? 'A scheduled commitment opens' : "#{commitments} scheduled commitments open"} a conversation in #{name}; let #{commitments == 1 ? 'it' : 'them'} run or cancel first")
    end
    rhythms = Rhythm.where(account_id: account_id, room_id: id, room_choice: "room").count
    if rhythms.positive?
      errors.add(:base, "#{rhythms == 1 ? 'A rhythm opens' : "#{rhythms} rhythms open"} conversations in #{name}; move #{rhythms == 1 ? 'it' : 'them'} to another room first")
    end
  end

  def name_is_not_main
    return unless name.to_s.casecmp?(MAIN) || (account && name.to_s.casecmp?(account.main_room_label))

    errors.add(:name, "#{account&.main_room_label || MAIN} is the default room")
  end

  def account_cannot_change
    errors.add(:account, "cannot be changed") if will_save_change_to_account_id?
  end

end
