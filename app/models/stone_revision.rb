require "stringio"

class StoneRevision < ApplicationRecord

  AUTHORED_ATTRIBUTES = %w[stone_id number title user_id agent_id policy_version interactive created_at].freeze

  belongs_to :stone
  belongs_to :user, optional: true
  belongs_to :agent, optional: true
  has_one_attached :html
  has_many :message_stone_revisions, dependent: :destroy
  has_many :messages, through: :message_stone_revisions
  has_many :stone_revision_field_tables, dependent: :delete_all
  has_many :field_tables, through: :stone_revision_field_tables

  # The tables this revision reads, as the stone receives them: name =>
  # { columns, rows }. Only live tables; a discarded table stops at once.
  def field_table_payload
    field_tables.kept.order(:id).to_h do |table|
      [ table.name, { columns: table.columns, rows: table.live_rows.map(&:data), updated_at: table.updated_at.iso8601 } ]
    end
  end

  validates :number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :stone_id }
  validates :title, presence: true, length: { maximum: 255 }
  validates :policy_version, presence: true
  validates :preview_status, inclusion: { in: %w[not_requested pending ready failed] }
  validate :exactly_one_author
  validate :authored_content_is_immutable, on: :update
  validate :validated_document_is_attached, on: :create

  def author=(principal)
    self.user = principal.is_a?(User) ? principal : nil
    self.agent = principal.is_a?(Agent) ? principal : nil
  end

  def author
    agent || user
  end

  def html_document=(document)
    raise Stone::InvalidInput, "HTML must be text" unless document.is_a?(String)
    raise Stone::InvalidInput, "HTML exceeds the 5 MiB limit" if document.bytesize > Stone::MAX_HTML_BYTES

    validator = interactive? ? Stone::InteractiveDocument : Stone::Document
    raise Stone::InvalidInput, "Interactive stones require a configured separate domain" if interactive? && !StoneHosting.domain
    original = validator.new(document).validate!
    self.policy_version = validator::POLICY_VERSION
    self.html = {
      io: StringIO.new(original), filename: "stone.html", content_type: "text/html",
      identify: false, metadata: { stone_html: true }
    }
    @validated_document_checksum = html.blob.checksum
  end

  # No blob URL or signed ID belongs in a presentation of this record.
  def html_document
    raise Stone::Withdrawn, "Stone has been withdrawn" if stone.reload.withdrawn?

    html.download
  end

  private

  def exactly_one_author
    errors.add(:base, "Exactly one author is required") unless user_id.present? ^ agent_id.present?
  end

  def validated_document_is_attached
    unless html.attached? && @validated_document_checksum.present? && html.blob.checksum == @validated_document_checksum
      errors.add(:html, "must be a validated standalone HTML document")
    end
  end

  def authored_content_is_immutable
    AUTHORED_ATTRIBUTES.each do |attribute|
      errors.add(attribute, "cannot change after publication") if will_save_change_to_attribute?(attribute)
    end
    errors.add(:html, "cannot change after publication") if attachment_changes.key?("html")
  end

end
