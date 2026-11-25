# One of an account's practices: a standing line about how the account works,
# read by every resident and guest on each wake in that account
# (AccountPractices::Renderer). People who manage the account and its home
# residents write them, with no approval step; guests only read them.
#
# A line is one line: surrounding whitespace is stripped and any line break
# is collapsed to a space, so nothing can put a heading into a wake prompt.
#
# Every write goes through add!/revise!/remove!, which lock the account row.
# The limits (MAX_LINES, MAX_TOTAL) are checked inside that lock, so two
# writers at once cannot both pass the check and together break the limit;
# the same lock keeps positions dense (1..n). Each write is audited in the
# same transaction.
class AccountPractice < ApplicationRecord

  MAX_LENGTH = 250
  MAX_LINES = 25
  MAX_TOTAL = 3_000

  belongs_to :account
  belongs_to :updated_by_user, class_name: "User", optional: true
  belongs_to :updated_by_agent, class_name: "Agent", optional: true

  before_validation :normalize_text

  validates :text, presence: true, length: { maximum: MAX_LENGTH }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 1 }

  scope :ordered, -> { order(:position, :id) }

  # Strip, and collapse every run of whitespace (line breaks included, and
  # the Unicode line and paragraph separators) to one space. Other control
  # characters are dropped.
  def self.clean(text)
    text.to_s.unicode_normalize(:nfc).gsub(/[\u0000-\u0008\u000E-\u001F\u007F]/, "").squish
  end

  def self.total_length(account)
    account.account_practices.sum("char_length(text)")
  end

  # Adds a line at `position` (1-based; default the end) on `by`'s say-so.
  def self.add!(account:, text:, by:, position: nil, request: nil)
    transaction do
      account.lock!
      lines = account.account_practices.ordered.to_a
      practice = account.account_practices.new(text:, position: lines.size + 1)
      practice.stamp(by)
      practice.validate_limits(lines)
      raise ActiveRecord::RecordInvalid, practice if practice.errors.any? || !practice.valid?

      practice.save!
      practice.move_within(lines + [ practice ], position) if position
      practice.audit!("add_account_practice", by:, request:)
      PracticeActivity.refresh!(account.id)
      practice
    end
  end

  # Changes the text, the position, or both. A revision that changes
  # neither leaves the line, its last editor and the audit log alone.
  def revise!(by:, text: nil, position: nil, request: nil)
    self.class.transaction do
      account.lock!
      reload
      lines = account.account_practices.ordered.to_a
      before = { text: self.text, position: self.position }
      self.text = self.class.clean(text) unless text.nil?
      moving = !position.nil? && position.to_i.clamp(1, lines.size) != self.position
      return self unless text_changed? || moving

      stamp(by)
      errors.clear # a refused attempt on this same object must not refuse the next
      validate_limits(lines.reject { |line| line.id == id })
      raise ActiveRecord::RecordInvalid, self if errors.any? || !valid?

      save!
      move_within(lines.map { |line| line.id == id ? self : line }, position) if moving
      action = before[:text] == self.text ? "reorder_account_practice" : "edit_account_practice"
      audit!(action, by:, request:, from_text: (before[:text] if action == "edit_account_practice"),
        from_position: (before[:position] if before[:position] != self.position))
      PracticeActivity.refresh!(account_id)
      self
    end
  end

  def remove!(by:, request: nil)
    self.class.transaction do
      account.lock!
      audit!("remove_account_practice", by:, request:)
      destroy!
      account.account_practices.ordered.each.with_index(1) do |line, index|
        line.update_column(:position, index) unless line.position == index
      end
      PracticeActivity.refresh!(account_id)
      self
    end
  end

  def updated_by
    if updated_by_agent
      { kind: "resident", id: updated_by_agent.to_param, name: updated_by_agent.name }
    elsif updated_by_user
      { kind: "person", name: updated_by_user.display_name }
    end
  end

  def as_json(*)
    {
      id: to_param,
      text:,
      position:,
      updated_at: updated_at&.iso8601,
      updated_by:
    }
  end

  # Records who last changed the line (a person or a resident).
  def stamp(by)
    case by
    when Agent
      self.updated_by_agent = by
      self.updated_by_user = nil
    when User
      self.updated_by_user = by
      self.updated_by_agent = nil
    end
  end

  # The account-wide limits, given the other lines. Called under the lock.
  def validate_limits(others)
    if new_record? && others.size >= MAX_LINES
      errors.add(:base, "An account can keep at most #{MAX_LINES} practices")
    end
    total = others.sum { |line| line.text.to_s.length } + self.class.clean(text).length
    if total > MAX_TOTAL
      errors.add(:base, "Practices can use at most #{MAX_TOTAL.to_fs(:delimited)} characters in total (this would be #{total.to_fs(:delimited)})")
    end
  end

  # Puts this line at `position` (clamped to 1..n) and renumbers the rest.
  def move_within(lines, position)
    target = position.to_i.clamp(1, lines.size)
    ordered = lines.reject { |line| line.id == id }
    ordered.insert(target - 1, self)
    ordered.each.with_index(1) do |line, index|
      line.update_column(:position, index) unless line.position == index
    end
  end

  def audit!(action, by:, request: nil, **extra)
    data = { practice_id: to_param, text:, position: }
    data.merge!(extra.compact)
    if by.is_a?(Agent)
      data.merge!(by: "resident", agent_id: by.id, agent_name: by.name)
    else
      data[:by] = "person"
    end
    data.merge!(request[:credential] || {}) if request
    AuditLog.create!(
      user: (by if by.is_a?(User)),
      account:,
      action:,
      auditable: (self unless destroyed?),
      data:,
      ip_address: request&.dig(:ip_address),
      user_agent: request&.dig(:user_agent)
    )
  end

  private

  def normalize_text
    self.text = self.class.clean(text)
  end

end
