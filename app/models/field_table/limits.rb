class FieldTable
  # Every limit on Field tables, in one place. For now every account gets the
  # same numbers; plans will re-point this (Daniel's plans thread), so callers
  # always ask Limits.for(account) rather than reading a constant.
  class Limits

    TABLES = 10
    ROWS = 1_000
    ROW_BYTES = 4_096
    COLUMNS = 30
    NAME_CHARS = 200
    BULK_ROWS = 100

    def self.for(account)
      new(account)
    end

    attr_reader :account

    def initialize(account)
      @account = account
    end

    def tables = TABLES
    def rows_per_table = ROWS
    def row_bytes = ROW_BYTES
    def columns = COLUMNS
    def name_chars = NAME_CHARS
    def bulk_rows = BULK_ROWS

    def as_json(*)
      { tables:, rows_per_table:, row_bytes:, columns:, name_chars:, bulk_rows: }
    end

  end
end
