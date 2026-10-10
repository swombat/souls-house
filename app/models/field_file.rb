# A file someone brought into an account's Field: material from their life
# that the account's humans and residents can read. Visibility is the account,
# the same as chats and whiteboards; per-item readers are deliberately later.
#
# Deleting discards: the row and the stored bytes are kept (a project rule),
# the file disappears from every reader, and HidesDiscardedBlobs (one rule for
# every discardable owner) stops already-issued blob URLs from serving it.
class FieldFile < ApplicationRecord

  include Discard::Model
  include Broadcastable
  include ObfuscatesId
  include SyncAuthorizable
  include FieldTaggable

  MAX_FILE_SIZE = 100.megabytes
  MAX_FILE_SIZE_LABEL = "100 MB"
  MAX_NOTE_LENGTH = 2_000

  belongs_to :account
  belongs_to :uploaded_by, polymorphic: true, optional: true

  has_one_attached :file
  # After the attachment: after_commit callbacks run in the order defined, and
  # extraction needs the bytes already uploaded.
  include FieldFile::TextExtraction
  include FieldSummarizable

  validates :title, presence: true, length: { maximum: 200 }
  validates :note, length: { maximum: MAX_NOTE_LENGTH }
  validate :file_present_and_bounded

  before_validation :default_title_from_filename
  before_save { self.indexed_filename = file.attached? ? file.filename.to_s.truncate(255) : nil }

  broadcasts_to :account

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  # Files whose words have been read (FieldSummarizable). PDFs and other
  # unread formats have none, so they get no summary yet.
  scope :summary_readable, -> { where.not(text_extracted_at: nil).where("extracted_text ~ '[^[:space:]]'") }

  def uploader_name
    case uploaded_by
    when User then uploaded_by.full_name.presence || uploaded_by.email_address.split("@").first
    when Agent then uploaded_by.name
    end
  end

  def uploader_kind
    case uploaded_by
    when User then "human"
    when Agent then "resident"
    end
  end

  def uploaded_by_agent?(agent)
    agent.present? && uploaded_by_type == "Agent" && uploaded_by_id == agent.id
  end

  def summary_source = extracted_text

  def filename = file.attached? ? file.filename.to_s : nil
  def content_type = file.attached? ? file.content_type : nil
  def byte_size = file.attached? ? file.byte_size : nil

  private

  def default_title_from_filename
    self.title = title.to_s.strip
    self.title = file.filename.to_s.truncate(200) if title.blank? && file.attached?
  end

  def file_present_and_bounded
    unless file.attached?
      errors.add(:file, "must be attached")
      return
    end

    if file.byte_size > MAX_FILE_SIZE
      errors.add(:file, "must be #{MAX_FILE_SIZE_LABEL} or smaller")
    end
  end

end
