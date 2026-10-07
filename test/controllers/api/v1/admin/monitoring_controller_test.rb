require "test_helper"

class Api::V1::Admin::MonitoringControllerTest < ActionDispatch::IntegrationTest

  setup do
    @admin = users(:site_admin_user)
    @headers = headers_for(@admin)
    @from = Time.utc(2026, 1, 1)
    @to = @from + 1.day
    @window = { from: @from.iso8601(6), to: @to.iso8601(6) }
    @paths = [ api_v1_admin_summary_path, api_v1_admin_accounts_path, api_v1_admin_users_path ]
  end

  test "all endpoints require authentication and reject ordinary and resident keys" do
    ordinary_headers = headers_for(users(:regular_user))
    resident_headers = headers_for(@admin, agent: agents(:research_assistant))
    @paths.each do |path|
      get path
      assert_response :unauthorized
      assert_equal "no-store", response.headers["Cache-Control"]
      get path, headers: { "Authorization" => "Bearer invalid" }
      assert_response :unauthorized
      get path, headers: ordinary_headers
      assert_response :forbidden
      get path, headers: resident_headers
      assert_response :forbidden
    end
  end

  test "direct site admin role is checked on every request and revoked keys are unauthorized" do
    @paths.each do |path|
      get path, headers: @headers
      assert_response :ok
      assert_equal "no-store", response.headers["Cache-Control"]
    end
    @admin.update!(is_site_admin: false)
    @paths.each do |path|
      get path, headers: @headers
      assert_response :forbidden
    end
    @key.destroy!
    @paths.each do |path|
      get path, headers: @headers
      assert_response :unauthorized
    end
  end

  test "confirmed enabled admin account membership grants authority and losing it revokes authority" do
    user = users(:user_1)
    account = accounts(:team_account)
    membership = memberships(:team_account_owner)
    account.update!(is_site_admin: true)
    headers = headers_for(user)
    @paths.each do |path|
      get path, headers: headers
      assert_response :ok
    end
    membership.update_columns(confirmed_at: nil)
    assert_all_forbidden(headers)
    membership.update_columns(confirmed_at: Time.current)
    account.disable!
    assert_all_forbidden(headers)
    account.enable!
    account.update!(is_site_admin: false)
    assert_all_forbidden(headers)
    account.update!(is_site_admin: true)
    membership.delete
    assert_all_forbidden(headers)
  end

  test "summary counts global signups separately from memberships and kept conversation activity" do
    account = accounts(:another_team)
    account.update_columns(created_at: @from)
    users(:unconfirmed_user).update_columns(created_at: @from)
    memberships(:another_team_member).update_columns(created_at: @from + 1.hour)
    users(:regular_user).update_columns(created_at: @to)
    accounts(:regular_user_account).update_columns(created_at: @to)

    chat = new_chat(account)
    new_message(chat, "user", @from)
    new_message(chat, "assistant", @to - 0.000001)
    new_message(chat, "user", @from - 0.000001)
    new_message(chat, "assistant", @to)
    new_message(chat, "system", @from + 1.hour)
    new_message(chat, "tool", @from + 1.hour)
    new_message(chat, "assistant", @from + 1.hour, progress_message: true)
    new_message(chat, "user", @from + 2.hours, discarded_at: @from + 3.hours)
    discarded_chat = new_chat(accounts(:team_account))
    discarded_chat.update_columns(discarded_at: @from + 1.hour)
    new_message(discarded_chat, "user", @from + 1.hour)
    progress_chat = new_chat(accounts(:other))
    new_message(progress_chat, "assistant", @from, progress_message: true)

    get api_v1_admin_summary_path, params: @window, headers: @headers
    assert_response :ok
    assert_equal({
      "new_accounts" => 1, "new_users" => 1, "active_accounts" => 1,
      "human_messages" => 1, "assistant_messages" => 1
    }, response.parsed_body["counts"])
    assert_equal @window.stringify_keys, response.parsed_body["window"]
    assert_match(/Z\z/, response.parsed_body["generated_at"])

    get api_v1_admin_accounts_path, params: @window, headers: @headers
    assert_equal [ account.to_param ], response.parsed_body["accounts"].pluck("id")
    get api_v1_admin_users_path, params: @window, headers: @headers
    assert_equal [ users(:unconfirmed_user).to_param ], response.parsed_body["users"].pluck("id")
  end

  test "default is trailing UTC day and empty periods are genuine zero counts" do
    travel_to Time.utc(2026, 1, 10, 12) do
      get api_v1_admin_summary_path, headers: @headers
      assert_response :ok
      assert_equal({
        "from" => "2026-01-09T12:00:00.000000Z", "to" => "2026-01-10T12:00:00.000000Z"
      }, response.parsed_body["window"])
      assert_equal "2026-01-10T12:00:00.000000Z", response.parsed_body["generated_at"]
      assert response.parsed_body["counts"].values.all?(&:zero?)
    end
    [ "accounts", "users" ].each do |kind|
      get "/api/v1/admin/#{kind}", params: @window, headers: @headers
      assert_response :ok
      assert_empty response.parsed_body[kind]
      assert_nil response.parsed_body["next_cursor"]
    end
  end

  test "all routes validate both UTC half open boundaries and maximum window" do
    invalid = [
      { from: @window[:from] }, { to: @window[:to] },
      @window.merge(from: ""), @window.merge(from: "yesterday"),
      @window.merge(from: [ @window[:from] ]),
      @window.merge(from: { time: @window[:from] }),
      @window.merge(from: "2026-01-01T00:00:00+00:00"),
      @window.merge(from: "2026-02-30T00:00:00Z"),
      @window.merge(from: "2026-01-01T24:00:00Z"),
      @window.merge(to: @window[:from]),
      @window.merge(to: (@from - 1.second).iso8601),
      @window.merge(to: (@from + 31.days + 1.second).iso8601)
    ]
    @paths.each do |path|
      invalid.each do |params|
        get path, params: params, headers: @headers
        assert_response :unprocessable_entity
        assert_equal [ "error" ], response.parsed_body.keys
      end
      get path, params: @window.merge(to: (@from + 31.days).iso8601), headers: @headers
      assert_response :ok
    end
  end

  test "account and user pages use stable ascending creation and id ordering with bounded cursors" do
    [ [ "accounts", Account ], [ "users", User ] ].each do |kind, model|
      records = model.order(:id).limit(3).to_a
      records.each { |record| record.update_columns(created_at: @from) }
      path = "/api/v1/admin/#{kind}"
      ids = []
      cursor = nil
      3.times do |index|
        params = @window.merge(limit: 1)
        params[:cursor] = cursor if cursor
        get path, params: params, headers: @headers
        assert_response :ok
        ids.concat(response.parsed_body[kind].pluck("id"))
        cursor = response.parsed_body["next_cursor"]
        index == 2 ? assert_nil(cursor) : assert(cursor.present?)
      end
      assert_equal records.map(&:to_param), ids
      records.each { |record| record.update_columns(created_at: @from - 1.day) }
    end
  end

  test "page sizes and malformed tampered wrong endpoint or wrong window cursors are rejected" do
    %w[accounts users].each do |kind|
      path = "/api/v1/admin/#{kind}"
      [ "", "0", "-1", "101", "999999", "1.5", "1x", "01", [ "2" ], { size: "2" } ].each do |limit|
        get path, params: @window.merge(limit: limit), headers: @headers
        assert_response :unprocessable_entity
      end
      [ "", "invalid", "a" * 2049, [ "invalid" ], { token: "invalid" } ].each do |cursor|
        get path, params: @window.merge(cursor: cursor), headers: @headers
        assert_response :unprocessable_entity
      end
      get path, params: @window.merge(limit: 100), headers: @headers
      assert_response :ok
    end
    Account.order(:id).limit(2).each { |account| account.update_columns(created_at: @from) }
    get api_v1_admin_accounts_path, params: @window.merge(limit: 1), headers: @headers
    cursor = response.parsed_body.fetch("next_cursor")
    [
      [ api_v1_admin_accounts_path, @window.merge(cursor: cursor + "x") ],
      [ api_v1_admin_users_path, @window.merge(cursor: cursor) ],
      [ api_v1_admin_accounts_path, @window.merge(cursor: cursor, to: (@to + 1.hour).iso8601) ],
      [ api_v1_admin_accounts_path, { cursor: cursor } ]
    ].each do |path, params|
      get path, params: params, headers: @headers
      assert_response :unprocessable_entity
    end
  end

  test "serializers are allowlisted and omit emails including default labels and all private fields" do
    account = accounts(:personal_account)
    owner = users(:user_1)
    account.update_columns(created_at: @from, name: "#{owner.email_address}'s Account")
    owner.update_columns(created_at: @from)
    owner.profile.update_columns(first_name: "", last_name: "")
    chat = new_chat(account)
    new_message(chat, "user", @from)

    get api_v1_admin_accounts_path, params: @window, headers: @headers
    payload = response.parsed_body
    assert_equal %w[accounts generated_at next_cursor window], payload.keys.sort
    row = payload.fetch("accounts").sole
    assert_equal %w[admin_path created_at id name owner], row.keys.sort
    assert_nil row["name"]
    assert_equal({ "id" => owner.to_param, "name" => nil }, row["owner"])
    assert_equal admin_accounts_path(account_id: account.to_param), row["admin_path"]
    assert_no_private_fields

    get api_v1_admin_users_path, params: @window, headers: @headers
    row = response.parsed_body.fetch("users").sole
    assert_equal %w[admin_path created_at id name], row.keys.sort
    assert_nil row["name"]
    assert_equal admin_accounts_path(account_id: account.to_param), row["admin_path"]
    assert_no_private_fields

    get api_v1_admin_summary_path, params: @window, headers: @headers
    assert_equal %w[counts generated_at window], response.parsed_body.keys.sort
    assert_no_private_fields
  end

  private

  def headers_for(user, agent: nil)
    @key = ApiKey.generate_for(user, name: "Monitoring tests", account: user.personal_account, agent: agent)
    { "Authorization" => "Bearer #{@key.raw_token}" }
  end

  def assert_all_forbidden(headers)
    @paths.each do |path|
      get path, headers: headers
      assert_response :forbidden
    end
  end

  def new_chat(account)
    Chat.create!(account: account, title: "PRIVATE CONVERSATION TITLE", model_id: "openai/gpt-4o")
  end

  def new_message(chat, role, time, **attributes)
    Message.create!(chat: chat, role: role, content: "PRIVATE MESSAGE CONTENT #{SecureRandom.hex(4)}",
      created_at: time, suppress_automatic_dispatch: true, **attributes)
  end

  def assert_no_private_fields
    assert_no_match(/PRIVATE CONVERSATION TITLE|PRIVATE MESSAGE CONTENT|@example\.com|token_digest|password|email_address|api_key|thinking|content|title/, response.body)
  end

end
