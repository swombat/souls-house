require "test_helper"

# The migration's backfill decides who keeps X posting on deploy. Run its
# INSERT against fresh rows: only connected, enabled integrations get grants.
class XPostingGrantBackfillTest < ActiveSupport::TestCase

  MIGRATION = Rails.root.join("db/migrate/20261119190000_create_x_posting_grants.rb")

  def backfill_sql
    MIGRATION.read[/execute <<~SQL\.squish\n(.*?)^\s*SQL$/m, 1].squish
  end

  test "backfill grants only accounts with a connected handle and posting on" do
    connected_on = XIntegration.create!(account: accounts(:team_account), enabled: true, access_token: "t", refresh_token: "rt")
    connected_off = XIntegration.create!(account: accounts(:another_team), enabled: false, access_token: "t", refresh_token: "rt")
    app_only = XIntegration.create!(account: accounts(:personal_account), enabled: true, client_id: "c", client_secret: "s")
    XPostingGrant.delete_all

    ActiveRecord::Base.connection.execute(backfill_sql)

    granted = XPostingGrant.pluck(:x_integration_id).uniq
    assert_equal [ connected_on.id ], granted
    assert_equal Agent.where(account_id: connected_on.account_id).count, XPostingGrant.count
    assert XPostingGrant.count.positive?, "fixture account should have residents"
    assert_not_includes granted, connected_off.id
    assert_not_includes granted, app_only.id
  end

end
