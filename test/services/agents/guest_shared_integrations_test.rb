require "test_helper"

# The Guest residents card lists, on each seat, what the account the resident
# sits in has shared with it (JXgGQY).
class Agents::GuestSharedIntegrationsTest < ActiveSupport::TestCase

  setup do
    @daniel = users(:user_1)
    @anna = users(:existing_user)
    @home = accounts(:personal_account)
    @sharing = accounts(:team_account)
    @lume = agents(:research_assistant)
    @seat = @sharing.guest_memberships.create!(agent: @lume, added_by: @daniel)
    @connection = @sharing.service_connections.create!(
      connected_by_user: @anna,
      provider: "google_workspace",
      external_subject_id: "google-anna",
      external_identity: "google-anna@example.test",
      management_scope: "personal",
      credential_kind: "oauth2",
      credential_payload_hash: { "access_token" => "a", "refresh_token" => "r", "expires_at" => 2.days.from_now.utc.iso8601 },
      credential_metadata: { "credential_strategy" => "refresh_broker", "granted_scopes" => [ "https://www.googleapis.com/auth/drive.readonly" ] }
    )
  end

  test "a seat with nothing shared carries an empty list" do
    assert_equal [], seat_json.fetch(:integrations)
  end

  test "a pending offer shows dimmed as awaiting the home, an approved one as shared" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)

    pending = seat_json.fetch(:integrations).sole
    assert_equal "google_workspace", pending[:provider]
    assert_not pending[:enabled]
    assert_equal "awaiting home approval", pending[:status]

    access.approve_home!(actor: @daniel, generation: access.home_approval_generation)

    approved = seat_json.fetch(:integrations).sole
    assert approved[:enabled]
    assert_equal "shared", approved[:status]
  end

  test "an offer the sharing side switched off is not listed" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    access.approve_home!(actor: @daniel, generation: access.home_approval_generation)
    @lume.set_service_access!(@connection, enabled: false, actor: @anna)

    assert_equal [], seat_json.fetch(:integrations)
  end

  test "an offer to one guest does not show on another guest's seat" do
    mira = Agent.create!(account: @home, name: "Mira", model_id: "openrouter/auto")
    other = @sharing.guest_memberships.create!(agent: mira, added_by: @daniel)
    @lume.set_service_access!(@connection, enabled: true, actor: @anna)

    rows = Agents::GuestSharedIntegrations.new([ @seat, other ]).as_json
    assert_equal 1, rows.first.fetch(:integrations).size
    assert_equal [], rows.second.fetch(:integrations)
  end

  private

  def seat_json
    Agents::GuestSharedIntegrations.new([ @seat.reload ]).as_json.sole
  end

end
