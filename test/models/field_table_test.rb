require "test_helper"

class FieldTableTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @table = FieldTable.create_in!(@account, name: "Build in public posts", by: @user, columns: [
      { key: "date", type: "date" }, { key: "platform" }, { key: "link", type: "link" },
      { key: "views", type: "number" }, { key: "sent", type: "boolean" }
    ])
  end

  test "columns default to text with a label from the key" do
    platform = @table.column("platform")
    assert_equal "text", platform.type
    assert_equal "Platform", platform.label
  end

  test "rows cast values to their column types" do
    row = @table.add_rows!([ { "date" => "2026-11-10", "views" => "12", "sent" => "yes", "link" => "https://x.com/a" } ], by: @user).first
    assert_equal({ "date" => "2026-11-10", "views" => 12, "sent" => true, "link" => "https://x.com/a" }, row.data)
  end

  test "a key that is not a column is refused and the error lists the columns" do
    error = assert_raises(FieldTable::Refused) { @table.add_rows!([ { "sentAt" => "2026-11-10" } ], by: @user) }
    assert_match "sentAt is not a column", error.message
    assert_match "date, platform, link, views, sent", error.message
    assert_equal @table.column_keys, error.details[:columns]
  end

  test "a value that does not fit its type is refused" do
    assert_raises(FieldTable::Refused) { @table.add_rows!([ { "views" => "lots" } ], by: @user) }
    assert_raises(FieldTable::Refused) { @table.add_rows!([ { "date" => "yesterday" } ], by: @user) }
    assert_raises(FieldTable::Refused) { @table.add_rows!([ { "link" => "javascript:alert(1)" } ], by: @user) }
    assert_raises(FieldTable::Refused) { @table.add_rows!([ { "sent" => "maybe" } ], by: @user) }
    assert_equal 0, @table.live_rows.count
  end

  test "a bulk add is all or nothing" do
    assert_raises(FieldTable::Refused) do
      @table.add_rows!([ { "platform" => "x" }, { "views" => "nope" } ], by: @user)
    end
    assert_equal 0, @table.live_rows.count
  end

  test "a row over the byte limit is refused with the limit" do
    error = assert_raises(FieldTable::Refused) { @table.add_rows!([ { "platform" => "a" * 5_000 } ], by: @user) }
    assert_match "at most 4096 bytes", error.message
  end

  test "update touches only the given keys, clears blanks, and refuses a stale lock_version" do
    row = @table.add_rows!([ { "platform" => "x", "views" => 3 } ], by: @user).first
    updated = @table.update_row!(row, { "views" => 4, "platform" => "" }, by: @user, lock_version: row.lock_version)
    assert_equal({ "views" => 4 }, updated.data)

    error = assert_raises(FieldTable::Stale) { @table.update_row!(row, { "views" => 5 }, by: @user, lock_version: 0) }
    assert_equal updated.lock_version, error.row.lock_version
    assert_equal 4, row.reload.data["views"]
  end

  test "without a lock_version the write wins for that row" do
    row = @table.add_rows!([ { "views" => 1 } ], by: @user).first
    @table.update_row!(row, { "views" => 2 }, by: @user)
    @table.update_row!(row, { "views" => 3 }, by: @user)
    assert_equal 3, row.reload.data["views"]
  end

  test "the row cap refuses rather than truncating" do
    FieldTableRow.insert_all(Array.new(FieldTable::Limits::ROWS - 1) { { field_table_id: @table.id, data: {} } })
    error = assert_raises(FieldTable::Refused) { @table.add_rows!([ {}, {} ], by: @user) }
    assert_match "at most 1000 rows", error.message
    assert_equal FieldTable::Limits::ROWS - 1, @table.live_rows.count
    @table.add_rows!([ {} ], by: @user)
    assert_equal FieldTable::Limits::ROWS, @table.live_rows.count
  end

  test "the table cap refuses an eleventh table" do
    (FieldTable::Limits::TABLES - @account.field_tables.kept.count).times { |i| FieldTable.create_in!(@account, name: "t#{i}") }
    error = assert_raises(FieldTable::Refused) { FieldTable.create_in!(@account, name: "one more") }
    assert_match "limit", error.message
  end

  test "names are unique among live tables, case-insensitively, and free again after delete" do
    assert_raises(FieldTable::Refused) { FieldTable.create_in!(@account, name: "build IN public posts") }
    @table.discard_by!(@user)
    assert FieldTable.create_in!(@account, name: "Build in public posts")
  end

  test "column count and key shape are checked" do
    assert_raises(FieldTable::Refused) { @table.add_column!({ key: "Sent At" }, by: @user) }
    assert_raises(FieldTable::Refused) { @table.add_column!({ key: "platform" }, by: @user) }
    assert_raises(FieldTable::Refused) { @table.add_column!({ key: "x", type: "formula" }, by: @user) }
    (FieldTable::Limits::COLUMNS - @table.column_list.size).times { |i| @table.add_column!({ key: "c#{i}" }, by: @user) }
    assert_raises(FieldTable::Refused) { @table.add_column!({ key: "one_more" }, by: @user) }
  end

  test "renaming a column key rewrites rows and bumps their lock_version" do
    row = @table.add_rows!([ { "platform" => "x" } ], by: @user).first
    @table.change_column!("platform", { key: "where_posted" }, by: @user)
    row.reload
    assert_equal({ "where_posted" => "x" }, row.data)
    assert_equal 1, row.lock_version
    assert_includes @table.reload.column_keys, "where_posted"
  end

  test "changing a column type converts values or refuses the change" do
    @table.add_rows!([ { "platform" => "12" } ], by: @user)
    @table.change_column!("platform", { type: "number" }, by: @user)
    assert_equal 12, @table.live_rows.first.data["platform"]

    @table.add_rows!([ { "platform" => 13 } ], by: @user)
    @table.change_column!("platform", { type: "text" }, by: @user)
    @table.add_rows!([ { "platform" => "x" } ], by: @user)
    assert_raises(FieldTable::Refused) { @table.change_column!("platform", { type: "number" }, by: @user) }
    assert_equal "text", @table.reload.column("platform").type
    assert_equal %w[12 13 x], @table.live_rows.map { |r| r.data["platform"] }
  end

  test "removing a column strips its values" do
    row = @table.add_rows!([ { "platform" => "x", "views" => 1 } ], by: @user).first
    @table.remove_column!("platform", by: @user)
    assert_equal({ "views" => 1 }, row.reload.data)
    assert_not_includes @table.reload.column_keys, "platform"
  end

  test "filter by equality and sort by a typed column" do
    @table.add_rows!([ { "platform" => "x", "views" => 10 }, { "platform" => "linkedin", "views" => 9 },
                       { "platform" => "x", "views" => 100 } ], by: @user)
    assert_equal [ 10, 100 ], @table.query_rows(where: { "platform" => "x" }).map { |r| r.data["views"] }
    assert_equal [ 100, 10, 9 ], @table.query_rows(sort: "-views").map { |r| r.data["views"] }
    assert_equal [ 9 ], @table.query_rows(where: { "views" => "9" }).map { |r| r.data["views"] }
    assert_raises(FieldTable::Refused) { @table.query_rows(sort: "nope") }
  end

  test "CSV import maps headers by key or label and refuses unknown headers" do
    @table.import_csv!("Platform,views\nx,3\nlinkedin,4\n", by: @user)
    assert_equal [ 3, 4 ], @table.live_rows.map { |r| r.data["views"] }
    assert_raises(FieldTable::Refused) { @table.import_csv!("platform,colour\nx,red\n", by: @user) }
    assert_equal "date,platform,link,views,sent\n", @table.to_csv.lines.first
  end

  test "a discarded table refuses writes" do
    @table.discard_by!(@user)
    assert_raises(FieldTable::Refused) { @table.add_rows!([ {} ], by: @user) }
  end

end

class FieldTableConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Table race #{SecureRandom.hex(4)}", account_type: "team")
    @table = FieldTable.create_in!(@account, name: "race", columns: [ { key: "n", type: "number" } ])
  end

  teardown do
    @account.destroy!
  end

  test "two adds racing for the last free row: exactly one lands" do
    FieldTableRow.insert_all(Array.new(FieldTable::Limits::ROWS - 1) { { field_table_id: @table.id, data: {} } })
    results = concurrently(2) do |i|
      FieldTable.find(@table.id).add_rows!([ { "n" => i } ], by: nil)
      :added
    rescue FieldTable::Refused
      :refused
    end
    assert_equal %i[added refused], results.sort
    assert_equal FieldTable::Limits::ROWS, @table.live_rows.count
  end

  test "two creates racing for the last table: exactly one lands" do
    (FieldTable::Limits::TABLES - 2).times { |i| FieldTable.create_in!(@account, name: "t#{i}") }
    results = concurrently(2) do |i|
      FieldTable.create_in!(Account.find(@account.id), name: "last #{i}")
      :added
    rescue FieldTable::Refused
      :refused
    end
    assert_equal %i[added refused], results.sort
  end

  private

  def concurrently(count)
    ready, start = Queue.new, Queue.new
    threads = count.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          yield i
        end
      end
    end
    count.times { ready.pop }
    count.times { start << true }
    threads.map(&:value)
  end

end
