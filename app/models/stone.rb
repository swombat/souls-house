class Stone < ApplicationRecord

  MAX_HTML_BYTES = 5.megabytes
  ACCOUNT_HTML_QUOTA = 100.megabytes

  class Conflict < StandardError; end
  class Withdrawn < StandardError; end
  class InvalidInput < StandardError; end

  belongs_to :chat
  has_secure_token :public_token, length: 32
  has_many :stone_revisions, dependent: :destroy
  has_many :message_stone_revisions, through: :stone_revisions

  scope :available, -> { where(withdrawn_at: nil) }

  def self.publish!(chat:, title:, html:, author:, public:)
    chat.account.with_lock do
      stone = create!(chat: chat)
      stone.revise!(title: title, html: html, author: author, public: public, base_revision_id: nil)
      stone
    end
  end

  def latest_revision
    stone_revisions.order(number: :desc).first
  end

  def withdrawn?
    withdrawn_at.present?
  end

  def public_param
    public_token
  end

  # The row lock serializes the base check and next number, including first
  # publication. The unique index is a second guard against duplicate numbers.
  def revise!(title:, html:, author:, public:, base_revision_id:)
    raise InvalidInput, "Explicit public: true acknowledgement is required" unless public == true
    raise InvalidInput, "title must be nonblank text of at most 255 characters" unless title.is_a?(String) && title.strip.present? && title.length <= 255
    raise InvalidInput, "Author must be a user or resident" unless author.is_a?(User) || author.is_a?(Agent)

    chat.account.with_lock do
      raise InvalidInput, "Conversation is archived or discarded" unless chat.reload.respondable?
      raise InvalidInput, "HTML must be text" unless html.is_a?(String)
      raise InvalidInput, "HTML exceeds the 5 MiB limit" if html.bytesize > MAX_HTML_BYTES

      with_lock do
        raise Withdrawn, "Stone has been withdrawn" if withdrawn?

        latest = latest_revision
        unless latest ? base_revision_id.to_s == latest.to_param : base_revision_id.nil?
          raise Conflict, "Stone has a newer revision; reload before revising"
        end
        raise InvalidInput, "Account HTML storage quota exceeded" if account_html_bytes + html.bytesize > ACCOUNT_HTML_QUOTA

        revision = stone_revisions.build(number: (latest&.number || 0) + 1, title: title)
        revision.author = author
        revision.html_document = html
        revision.save!
        revision
      end
    end
  end

  # Keep the stone and its authored history as a tombstone. Delivery must check
  # withdrawn_at before accessing any attachment, even while purge is pending.
  def withdraw!
    with_lock do
      update!(withdrawn_at: Time.current) unless withdrawn?
    end
    stone_revisions.includes(html_attachment: :blob).find_each { |revision| revision.html.purge_later }
    self
  end

  private

  def account_html_bytes
    revision_ids = StoneRevision.joins(stone: :chat).where(chats: { account_id: chat.account_id }).select(:id)
    ActiveStorage::Attachment.where(record_type: "StoneRevision", name: "html", record_id: revision_ids)
      .joins(:blob).sum("active_storage_blobs.byte_size")
  end

end
