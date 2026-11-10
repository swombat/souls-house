# A small table in an account's Field: declared columns, rows of jsonb data.
# People and residents see the same rows. Every write goes through a method
# here that takes a row lock on the table first, so two concurrent adds can't
# both pass a cap, and a column change can't race a row write. Limits come
# from FieldTable::Limits.for(account), never from constants at call sites.
class FieldTable < ApplicationRecord

  include Discard::Model
  include ObfuscatesId
  include Broadcastable
  include SyncAuthorizable

  # A refusal the caller can show as it is: a 422 with a readable reason.
  class Refused < StandardError

    attr_reader :details

    def initialize(message, details = {})
      super(message)
      @details = details
    end

  end

  # The write named a lock_version the row no longer has: a 409 with the row.
  class Stale < StandardError

    attr_reader :row

    def initialize(row)
      super("Row #{row.to_param} was changed since you read it (lock_version is now #{row.lock_version})")
      @row = row
    end

  end

  belongs_to :account
  belongs_to :created_by, polymorphic: true, optional: true
  belongs_to :updated_by, polymorphic: true, optional: true
  has_many :rows, -> { order(:id) }, class_name: "FieldTableRow", dependent: :delete_all, inverse_of: :field_table

  broadcasts_to :account

  validates :name, presence: true
  validate :name_within_limit
  validate :name_unique_among_live

  scope :by_name, -> { order(Arel.sql("lower(name)")) }

  def limits
    Limits.for(account)
  end

  def column_list
    Array(columns).map { |hash| Column.from_hash(hash) }
  end

  def column(key)
    column_list.find { |column| column.key == key.to_s }
  end

  def column_keys
    column_list.map(&:key)
  end

  def live_rows
    rows.kept
  end

  def editor_name(record = updated_by)
    case record
    when User then record.full_name.presence || record.email_address.split("@").first
    when Agent then record.name
    end
  end

  # -- Creating -------------------------------------------------------------

  # Creates a table under a lock on the account row, so the table cap holds.
  def self.create_in!(account, name:, columns: [], by: nil)
    limits = Limits.for(account)
    transaction do
      account.lock!
      if account.field_tables.kept.count >= limits.tables
        raise Refused, "This account already has #{limits.tables} tables, the limit (delete one to make another)"
      end

      table = account.field_tables.new(name: name.to_s.strip, columns: [], created_by: by, updated_by: by)
      table.columns = validated_columns(Array(columns).map { |c| column_from_param(c) }, limits)
      raise Refused, table.errors.full_messages.to_sentence unless table.save

      table
    end
  end

  def self.column_from_param(param)
    param = param.to_unsafe_h if param.respond_to?(:to_unsafe_h)
    raise Refused, "Each column must be an object with a key" unless param.is_a?(Hash)

    Column.from_hash(param)
  end

  def self.validated_columns(list, limits)
    raise Refused, "A table can have at most #{limits.columns} columns" if list.size > limits.columns

    list.each do |column|
      problem = column.problem(limits)
      raise Refused, problem if problem
    end
    duplicates = list.map(&:key).tally.select { |_, n| n > 1 }.keys
    raise Refused, "Column keys must be unique (repeated: #{duplicates.join(', ')})" if duplicates.any?

    list.map(&:to_h)
  end

  # -- Table changes --------------------------------------------------------

  def rename!(name, by:)
    locked do
      self.name = name.to_s.strip
      self.updated_by = by
      raise Refused, errors.full_messages.to_sentence unless save
    end
  end

  def discard_by!(by)
    locked do
      self.updated_by = by
      discard!
    end
  end

  # -- Columns --------------------------------------------------------------

  def add_column!(param, by:)
    locked do
      column = self.class.column_from_param(param)
      raise Refused, "Column #{column.key} already exists" if column_keys.include?(column.key)

      self.columns = self.class.validated_columns(column_list + [ column ], limits)
      self.updated_by = by
      save!
      column
    end
  end

  # Changes a column's key, label or type. A new key rewrites that key in
  # every row; a new type converts every live value or refuses the change.
  def change_column!(key, param, by:)
    locked do
      current = column(key) or raise Refused, "No column #{key} (columns: #{column_keys.join(', ')})"
      param = param.to_unsafe_h if param.respond_to?(:to_unsafe_h)
      param = param.to_h.stringify_keys
      changed = Column.new(key: param.fetch("key", current.key), label: param.fetch("label", current.label),
        type: param.fetch("type", current.type))
      if changed.key != current.key && column_keys.include?(changed.key)
        raise Refused, "Column #{changed.key} already exists"
      end

      list = column_list.map { |c| c.key == current.key ? changed : c }
      self.columns = self.class.validated_columns(list, limits)
      convert_values!(current, changed) if changed.type != current.type
      rename_key!(current.key, changed.key) if changed.key != current.key
      self.updated_by = by
      save!
      changed
    end
  end

  # Removes a column and its values from every row.
  def remove_column!(key, by:)
    locked do
      current = column(key) or raise Refused, "No column #{key} (columns: #{column_keys.join(', ')})"
      self.columns = column_list.reject { |c| c.key == current.key }.map(&:to_h)
      rows.where("data ? :key", key: current.key)
        .update_all([ "data = data - :key, lock_version = lock_version + 1, updated_at = now()", { key: current.key } ])
      self.updated_by = by
      save!
    end
  end

  # -- Rows -----------------------------------------------------------------

  # Adds one or more rows (each a Hash of column key => value) as one write:
  # all of them or none. Refuses past the row cap rather than truncating.
  def add_rows!(list, by:)
    list = Array(list)
    raise Refused, "Send at least one row" if list.empty?

    locked do
      room = limits.rows_per_table - live_rows.count
      if list.size > room
        raise Refused, "#{name} holds at most #{limits.rows_per_table} rows; it has #{limits.rows_per_table - room}, " \
                       "so #{list.size} more would pass the limit (nothing was added)"
      end

      created = list.each_with_index.map do |data, index|
        clean = prepared_data({}, data, position: (index + 1 if list.size > 1))
        rows.create!(data: clean, last_written_by: by)
      end
      touch_by!(by)
      created
    end
  end

  # Changes the given keys of one row; nil or "" clears a cell. With a
  # lock_version, a row changed since then is refused (Stale); without one,
  # this write wins for this row only.
  def update_row!(row, data, by:, lock_version: nil)
    locked do
      row = live_rows.lock.find(row.id)
      raise Stale, row if !lock_version.nil? && row.lock_version != lock_version

      row.data = prepared_data(row.data, data)
      row.last_written_by = by
      row.save!
      touch_by!(by)
      row
    end
  end

  def discard_row!(row, by:, lock_version: nil)
    locked do
      row = live_rows.lock.find(row.id)
      raise Stale, row if !lock_version.nil? && row.lock_version != lock_version

      row.update!(discarded_at: Time.current, last_written_by: by)
      touch_by!(by)
      row
    end
  end

  # -- Reading --------------------------------------------------------------

  # where: { key => value } (equality, cast by the column's type);
  # sort: "key" or "-key" (or created / -created).
  def query_rows(where: {}, sort: nil)
    scope = live_rows
    where.to_h.each do |key, value|
      column = column(key) or raise Refused.new("No column #{key} to filter on (columns: #{column_keys.join(', ')})",
        { columns: column_keys })
      cast = begin
        column.cast(value)
      rescue Column::Invalid => e
        raise Refused, e.message
      end
      scope = cast.nil? ? scope.where.not("data ? :key", key: column.key) : scope.where("data @> ?", { column.key => cast }.to_json)
    end
    order_rows(scope, sort)
  end

  def to_csv(list = live_rows)
    require "csv"
    keys = column_keys
    CSV.generate do |csv|
      csv << column_list.map(&:key)
      list.each { |row| csv << keys.map { |key| row.data[key] } }
    end
  end

  # Reads a CSV whose header names columns (by key or label) into rows, then
  # adds them as one write. Unknown headers and bad values refuse the whole
  # import with the line number; past the cap refuses too, never truncates.
  def import_csv!(text, by:)
    require "csv"
    parsed = CSV.parse(text.to_s.sub(/\A﻿/, ""), headers: true)
    headers = Array(parsed.headers).map { |h| h.to_s.strip }
    raise Refused, "The CSV has no header row" if headers.empty? || headers.all?(&:blank?)

    mapping = headers.map do |header|
      found = column_list.find { |c| c.key == header } || column_list.find { |c| c.label.casecmp?(header) }
      found or raise Refused.new("CSV column #{header.inspect} is not a column of #{name} (columns: #{column_keys.join(', ')})",
        { columns: column_keys })
    end
    list = parsed.map do |record|
      mapping.each_with_index.to_h { |column, index| [ column.key, record[index] ] }
    end
    raise Refused, "The CSV has no rows" if list.empty?

    add_rows!(list, by:)
  rescue CSV::MalformedCSVError => e
    raise Refused, "Couldn't read the CSV: #{e.message}"
  end

  private

  def locked(&block)
    transaction do
      lock!
      raise Refused, "This table has been deleted" if discarded?

      block.call
    end
  end

  # Row writes touch the table so its page and stones see one fresh marker.
  def touch_by!(by)
    self.updated_by = by
    self.updated_at = Time.current
    save!
  end

  # Merges changes into existing data: unknown keys refused (listing the
  # columns), values cast to type, blanks removed, size checked.
  def prepared_data(existing, changes, position: nil)
    changes = changes.to_unsafe_h if changes.respond_to?(:to_unsafe_h)
    where = position ? "Row #{position}: " : ""
    raise Refused, "#{where}a row must be an object of column => value" unless changes.is_a?(Hash)

    data = existing.to_h.dup
    unknown = changes.keys.map(&:to_s) - column_keys
    if unknown.any?
      raise Refused.new("#{where}#{unknown.join(', ')} #{unknown.one? ? 'is not a column' : 'are not columns'} " \
                        "of #{name} (columns: #{column_keys.join(', ')})", { columns: column_keys })
    end

    changes.each do |key, value|
      cast = column(key).cast(value)
      cast.nil? ? data.delete(key.to_s) : data[key.to_s] = cast
    end
    bytes = data.to_json.bytesize
    raise Refused, "#{where}a row can hold at most #{limits.row_bytes} bytes; this one is #{bytes}" if bytes > limits.row_bytes

    data
  rescue Column::Invalid => e
    raise Refused, "#{where}#{e.message}"
  end

  def convert_values!(from, to)
    live_rows.where("data ? :key", key: from.key).find_each do |row|
      converted = begin
        to.cast(row.data[from.key])
      rescue Column::Invalid => e
        raise Refused, "Can't make #{from.key} a #{to.type} column: in row #{row.to_param}, #{e.message}"
      end
      data = row.data.merge(from.key => converted).compact
      row.update_columns(data: data, lock_version: row.lock_version + 1, updated_at: Time.current)
    end
  end

  def rename_key!(old_key, new_key)
    rows.where("data ? :key", key: old_key).update_all([
      "data = (data - :old) || jsonb_build_object(:new, data -> :old), lock_version = lock_version + 1, updated_at = now()",
      { old: old_key, new: new_key }
    ])
  end

  def order_rows(scope, sort)
    return scope.reorder(:id) if sort.blank?

    descending = sort.to_s.start_with?("-")
    key = sort.to_s.delete_prefix("-")
    direction = descending ? "DESC" : "ASC"
    return scope.reorder(id: descending ? :desc : :asc) if key == "created"

    column = column(key) or raise Refused.new("No column #{key} to sort by (columns: #{column_keys.join(', ')}, created)",
      { columns: column_keys })
    quoted = self.class.connection.quote(column.key)
    expression = case column.type
    when "number" then "(data ->> #{quoted})::numeric"
    when "text", "link" then "lower(data ->> #{quoted})"
    else "data ->> #{quoted}"
    end
    scope.reorder(Arel.sql("#{expression} #{direction} NULLS LAST, field_table_rows.id #{direction}"))
  end

  def name_within_limit
    return if name.blank? || account.nil?

    errors.add(:name, "is longer than #{limits.name_chars} characters") if name.length > limits.name_chars
  end

  def name_unique_among_live
    return if name.blank? || account_id.nil? || discarded?

    clash = FieldTable.kept.where(account_id: account_id).where("lower(name) = ?", name.downcase).where.not(id: id)
    errors.add(:name, "is already used by another table in this Field") if clash.exists?
  end

end
