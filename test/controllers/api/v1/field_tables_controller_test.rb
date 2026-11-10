require "test_helper"

class Api::V1::FieldTablesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @resident = agents(:research_assistant)
    @account = @resident.account
    @headers = headers_for(@resident)
  end

  test "requires a token" do
    get api_v1_field_tables_path
    assert_response :unauthorized
  end

  test "a resident creates a table, adds rows, reads them back filtered and sorted" do
    post api_v1_field_tables_path, headers: @headers, as: :json, params: {
      name: "Build in public posts",
      columns: [ { key: "date", type: "date" }, { key: "platform" }, { key: "link", type: "link" }, { key: "views", type: "number" } ]
    }
    assert_response :created
    table = json["field_table"]
    assert_equal %w[date platform link views], table["columns"].map { |c| c["key"] }
    assert_equal 1_000, table["limits"]["rows"]

    post bulk_api_v1_field_table_rows_path(table["id"]), headers: @headers, as: :json, params: {
      rows: [ { date: "2026-11-10", platform: "x", views: 5 }, { date: "2026-11-09", platform: "linkedin", views: 50 } ]
    }
    assert_response :created
    assert_equal 2, json["rows"].size

    get api_v1_field_table_rows_path(table["id"]), headers: @headers, params: { where: { platform: "x" } }
    assert_response :success
    assert_equal [ 5 ], json["rows"].map { |r| r["data"]["views"] }
    assert_equal 1, json["total"]

    get api_v1_field_table_rows_path(table["id"]), headers: @headers, params: { sort: "-views" }
    assert_equal [ 50, 5 ], json["rows"].map { |r| r["data"]["views"] }
    assert_equal @resident.name, json["rows"].first["written_by"]

    get api_v1_field_table_path(table["id"]), headers: @headers
    assert_equal 2, json["field_table"]["row_count"]
    assert_equal 2, json["field_table"]["rows"].size
  end

  test "an unknown key is a 422 that lists the columns" do
    table = make_table
    post api_v1_field_table_rows_path(table), headers: @headers, as: :json, params: { data: { sentAt: "2026-11-10" } }
    assert_response :unprocessable_entity
    assert_match "sentAt is not a column", json["error"]
    assert_equal %w[date views], json["columns"]
  end

  test "a type mismatch is a 422" do
    table = make_table
    post api_v1_field_table_rows_path(table), headers: @headers, as: :json, params: { data: { views: "lots" } }
    assert_response :unprocessable_entity
    assert_match "views must be a number", json["error"]
  end

  test "a stale lock_version is a 409 with the current row; omitting it writes" do
    table = make_table
    row = table.add_rows!([ { "views" => 1 } ], by: @user).first
    patch api_v1_field_table_row_path(table, row), headers: @headers, as: :json, params: { data: { views: 2 }, lock_version: 0 }
    assert_response :success
    assert_equal 1, json["row"]["lock_version"]

    patch api_v1_field_table_row_path(table, row), headers: @headers, as: :json, params: { data: { views: 3 }, lock_version: 0 }
    assert_response :conflict
    assert_equal 2, json["row"]["data"]["views"]
    assert_equal 1, json["row"]["lock_version"]

    patch api_v1_field_table_row_path(table, row), headers: @headers, as: :json, params: { data: { views: 4 } }
    assert_response :success
    assert_equal 4, row.reload.data["views"]
  end

  test "columns change in one call each" do
    table = make_table
    table.add_rows!([ { "views" => 7 } ], by: @user)
    post api_v1_field_table_columns_path(table), headers: @headers, as: :json, params: { key: "status", label: "Status" }
    assert_response :created
    patch api_v1_field_table_column_path(table, "views"), headers: @headers, as: :json, params: { new_key: "reach" }
    assert_response :success
    assert_equal({ "reach" => 7 }, table.live_rows.first.reload.data)
    delete api_v1_field_table_column_path(table, "status"), headers: @headers
    assert_response :success
    assert_equal %w[date reach], table.reload.column_keys
  end

  test "rows are discarded, not destroyed, and leave reads" do
    table = make_table
    row = table.add_rows!([ { "views" => 1 } ], by: @user).first
    delete api_v1_field_table_row_path(table, row), headers: @headers
    assert_response :no_content
    assert row.reload.discarded?
    get api_v1_field_table_row_path(table, row), headers: @headers
    assert_response :not_found
  end

  test "a bulk add past the per-call limit is refused" do
    table = make_table
    post bulk_api_v1_field_table_rows_path(table), headers: @headers, as: :json, params: { rows: Array.new(101) { { views: 1 } } }
    assert_response :unprocessable_entity
    assert_equal 0, table.live_rows.count
  end

  test "another account's table is 404, for reads and writes" do
    other = accounts(:team_account)
    other = accounts(:existing_user_account) if other == @account
    foreign = FieldTable.create_in!(other, name: "theirs", columns: [ { key: "n" } ])
    row = foreign.add_rows!([ { "n" => "x" } ], by: nil).first

    get api_v1_field_table_path(foreign), headers: @headers
    assert_response :not_found
    patch api_v1_field_table_row_path(foreign, row), headers: @headers, as: :json, params: { data: { n: "y" } }
    assert_response :not_found
    delete api_v1_field_table_path(foreign), headers: @headers
    assert_response :not_found
    get api_v1_field_tables_path, headers: @headers
    assert_not_includes json["field_tables"].map { |t| t["id"] }, foreign.to_param
    assert_equal "x", row.reload.data["n"]
    assert_not foreign.reload.discarded?
  end

  test "a guest resident naming the account it visits gets 404 (Field tables are home-only)" do
    other = accounts(:team_account)
    other = accounts(:existing_user_account) if other == @account
    other.guest_memberships.create!(agent: @resident, added_by: @user)
    foreign = FieldTable.create_in!(other, name: "theirs")

    get api_v1_field_tables_path(account_id: other.to_param), headers: @headers
    assert_response :not_found
    get api_v1_field_table_path(foreign, account_id: other.to_param), headers: @headers
    assert_response :not_found
    post api_v1_field_tables_path(account_id: other.to_param), headers: @headers, as: :json, params: { name: "sneak" }
    assert_response :not_found
    assert_not other.field_tables.exists?(name: "sneak")
  end

  test "a resident deletes only tables it made; a person deletes any" do
    mine = FieldTable.create_in!(@account, name: "mine", by: @resident)
    theirs = FieldTable.create_in!(@account, name: "theirs", by: @user)

    delete api_v1_field_table_path(theirs), headers: @headers
    assert_response :forbidden
    delete api_v1_field_table_path(mine), headers: @headers
    assert_response :no_content
    assert mine.reload.discarded?

    human = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: 'Human', account: @account).raw_token}" }
    delete api_v1_field_table_path(theirs), headers: human
    assert_response :no_content
    assert theirs.reload.discarded?
  end

  test "a discarded table is 404" do
    table = make_table
    table.discard_by!(@user)
    get api_v1_field_table_path(table), headers: @headers
    assert_response :not_found
  end

  private

  def make_table
    FieldTable.create_in!(@account, name: "t #{SecureRandom.hex(3)}", by: @user,
      columns: [ { key: "date", type: "date" }, { key: "views", type: "number" } ])
  end

  def json
    JSON.parse(response.body)
  end

  def headers_for(agent)
    key = ApiKey.generate_for(@user, name: "Field tests", agent: agent)
    { "Authorization" => "Bearer #{key.raw_token}" }
  end

end
