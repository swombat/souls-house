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
  # Reservations survive physical deletion and are never recycled.
  has_one :stone_address

  scope :available, -> { where(withdrawn_at: nil) }

  def self.publish!(chat:, title:, html:, author:, public:, interactive: false, field_table_ids: [], publish_tables: false)
    chat.account.with_lock do
      stone = create!(chat: chat)
      stone.revise!(title: title, html: html, author: author, public: public, base_revision_id: nil, interactive: interactive,
        field_table_ids: field_table_ids, publish_tables: publish_tables)
      StoneAddress.reserve!(stone: stone) if StoneHosting.domain
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

  def public_url(number: nil)
    if StoneHosting.domain
      address = stone_address || with_lock { stone_address || StoneAddress.reserve!(stone: self) }
      path = number ? "/revisions/#{number}" : "/"
      "https://#{address.name}.#{StoneHosting.domain}#{path}"
    else
      "/stones/#{public_token}#{"/revisions/#{number}" if number}"
    end
  end

  # The row lock serializes the base check and next number, including first
  # publication. The unique index is a second guard against duplicate numbers.
  def revise!(title:, html:, author:, public:, base_revision_id:, interactive: false, field_table_ids: [], publish_tables: false)
    raise InvalidInput, "Explicit public: true acknowledgement is required" unless public == true
    raise InvalidInput, "title must be nonblank text of at most 255 characters" unless title.is_a?(String) && title.strip.present? && title.length <= 255
    raise InvalidInput, "Author must be a user or resident" unless author.is_a?(User) || author.is_a?(Agent)
    raise InvalidInput, "interactive must be true or false" unless [ true, false ].include?(interactive)
    raise InvalidInput, "Interactive stones require a configured separate domain" if interactive && !StoneHosting.domain

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

        revision = stone_revisions.build(number: (latest&.number || 0) + 1, title: title, interactive: interactive)
        revision.author = author
        revision.html_document = html
        tables = tables_to_attach(field_table_ids, author:, interactive:, publish_tables:)
        revision.save!
        tables.each { |table| revision.stone_revision_field_tables.create!(field_table: table, attached_by: author) }
        revision
      end
    end
  end

  # Withdrawal removes publication, not authored history. Keep every revision
  # and its original HTML attached for authorised recovery; delivery checks
  # withdrawn_at rather than relying on destruction of the bytes.
  def withdraw!
    with_lock do
      update!(withdrawn_at: Time.current) unless withdrawn?
    end
    self
  end

  private

  # Field tables a revision reads (slice 2): only for interactive revisions,
  # only the conversation's own account's live tables, only for an author whose
  # home that account is, and only with the explicit acknowledgement that the
  # rows become public with the stone.
  def tables_to_attach(ids, author:, interactive:, publish_tables:)
    ids = Array(ids).map(&:to_s).reject(&:blank?).uniq
    return [] if ids.empty?

    raise InvalidInput, "Tables can be attached only to an interactive stone (the page reads them with JavaScript)" unless interactive
    unless publish_tables == true
      raise InvalidInput, "Attaching a table publishes its rows to anyone with the stone's link; " \
                          "acknowledge with publish_tables: true (--publish-tables)"
    end
    if ids.size > StoneRevisionFieldTable::MAX_PER_REVISION
      raise InvalidInput, "A revision can read at most #{StoneRevisionFieldTable::MAX_PER_REVISION} tables"
    end
    home = author.is_a?(Agent) ? author.account_id == chat.account_id : chat.account.users.exists?(author.id)
    raise InvalidInput, "Only tables in your own home Field can be attached" unless home

    decoded = ids.map { |id| FieldTable.decode_id(id) }
    tables = chat.account.field_tables.kept.where(id: decoded.compact).to_a
    missing = ids.reject.with_index { |_, index| tables.any? { |table| table.id == decoded[index] } }
    raise InvalidInput, "No table #{missing.join(', ')} in this account's Field" if missing.any?

    tables
  rescue Hashids::InputError
    raise InvalidInput, "No table #{ids.join(', ')} in this account's Field"
  end

  def account_html_bytes
    revision_ids = StoneRevision.joins(stone: :chat).where(chats: { account_id: chat.account_id }).select(:id)
    ActiveStorage::Attachment.where(record_type: "StoneRevision", name: "html", record_id: revision_ids)
      .joins(:blob).sum("active_storage_blobs.byte_size")
  end

end
