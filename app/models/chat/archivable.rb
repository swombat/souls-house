module Chat::Archivable

  extend ActiveSupport::Concern

  included do
    scope :kept, -> { undiscarded }
    scope :archived, -> { where.not(archived_at: nil) }
    scope :active, -> { where(archived_at: nil) }
    before_validation -> { self.visual_tag = nil if archived? }
  end

  def archive!
    with_lock do
      update!(archived_at: Time.current, visual_tag: nil)
      ReplyExpectation.joins(:message).state_open.where(messages: { chat_id: id }).find_each(&:dismiss!)
    end
  end

  def unarchive!
    with_lock do
      changes = { archived_at: nil }
      if archived? && work_completions.exists?
        changes[:work_status_revision] = work_status_revision + 1
      end
      update!(changes)
    end
  end

  def archived?
    archived_at.present?
  end

  def archived
    archived?
  end

  def discarded
    discarded?
  end

  def respondable?
    !archived? && !discarded?
  end

  def respondable
    respondable?
  end

end
