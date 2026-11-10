require "test_helper"

class FieldTablesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    Setting.instance.update!(allow_agents: true)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
    @table = FieldTable.create_in!(@account, name: "Posts", by: @user,
      columns: [ { key: "platform" }, { key: "views", type: "number" } ])
  end

  def props = inertia_props["props"]

  test "the list shows live tables with row counts" do
    @table.add_rows!([ { "platform" => "x" } ], by: @user)
    gone = FieldTable.create_in!(@account, name: "Gone")
    gone.discard_by!(@user)

    get account_field_tables_path(@account)
    assert_response :success
    assert_equal "field/tables/index", inertia_component
    assert_equal [ [ "Posts", 1 ] ], props["tables"].map { |t| [ t["name"], t["row_count"] ] }
  end

  test "making a table starts it with a Name column and opens it" do
    post account_field_tables_path(@account), params: { name: "Reading list" }
    table = @account.field_tables.kept.find_by!(name: "Reading list")
    assert_redirected_to account_field_table_path(@account, table)
    assert_equal %w[name], table.column_keys
  end

  test "the table page carries rows and limits" do
    @table.add_rows!([ { "platform" => "x", "views" => 3 } ], by: @user)
    get account_field_table_path(@account, @table)
    assert_equal "field/tables/show", inertia_component
    assert_equal [ { "platform" => "x", "views" => 3 } ], props["rows"].map { |r| r["data"] }
    assert_equal 1_000, props["limits"]["rows_per_table"]
  end

  test "rows are added, edited with lock_version and deleted from the grid" do
    post account_field_table_rows_path(@account, @table), params: { data: { platform: "x", views: "4" } }
    row = @table.live_rows.last
    assert_equal({ "platform" => "x", "views" => 4 }, row.data)

    patch account_field_table_row_path(@account, @table, row), params: { data: { platform: "x", views: "" }, lock_version: row.lock_version }
    assert_equal({ "platform" => "x" }, row.reload.data)

    patch account_field_table_row_path(@account, @table, row), params: { data: { platform: "y" }, lock_version: 0 }
    assert_equal "x", row.reload.data["platform"], "a stale edit from the grid must not land"

    delete account_field_table_row_path(@account, @table, row)
    assert row.reload.discarded?
  end

  test "a refused write comes back as an error, not a 500" do
    post account_field_table_rows_path(@account, @table), params: { data: { colour: "red" } }
    assert_redirected_to account_field_table_path(@account, @table)
    assert_equal 0, @table.live_rows.count
  end

  test "CSV export and import round-trip, and an import past the limit adds nothing" do
    post import_account_field_table_path(@account, @table), params: { file: csv_upload("platform,views\nx,1\nlinkedin,2\n") }
    assert_equal 2, @table.live_rows.count

    get export_account_field_table_path(@account, @table)
    assert_response :success
    assert_equal "platform,views\nx,1\nlinkedin,2\n", response.body

    FieldTableRow.insert_all(Array.new(FieldTable::Limits::ROWS - 3) { { field_table_id: @table.id, data: {} } })
    post import_account_field_table_path(@account, @table), params: { file: csv_upload("platform\na\nb\n") }
    assert_equal FieldTable::Limits::ROWS - 1, @table.live_rows.count
  end

  test "columns are added, renamed and removed" do
    post account_field_table_columns_path(@account, @table), params: { key: "link", label: "Link", type: "link" }
    patch account_field_table_column_path(@account, @table, "link"), params: { new_key: "url" }
    delete account_field_table_column_path(@account, @table, "platform")
    assert_equal %w[views url], @table.reload.column_keys
  end

  test "another account's table is not found" do
    other = accounts(:team_account)
    other = accounts(:existing_user_account) if other == @account
    foreign = FieldTable.create_in!(other, name: "theirs")
    get account_field_table_path(@account, foreign)
    assert_response :not_found
  end

  test "deleting a table discards it" do
    delete account_field_table_path(@account, @table)
    assert_redirected_to account_field_tables_path(@account)
    assert @table.reload.discarded?
  end

  private

  def csv_upload(text)
    file = Tempfile.new([ "rows", ".csv" ])
    file.write(text)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/csv")
  end

end
