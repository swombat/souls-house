require "test_helper"

# Guest integration grants (JWblqj): Anna's house (the team account) shares a
# connection with Lume (hosted in Daniel's personal account, seated in the
# team account as a guest); Daniel's house approves.
class GuestIntegrationGrantTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper
  include ActionCable::TestHelper

  DRIVE_READ = "https://www.googleapis.com/auth/drive.readonly".freeze
  DRIVE_WRITE = "https://www.googleapis.com/auth/drive".freeze

  setup do
    @daniel = users(:user_1)         # owner of both accounts
    @anna = users(:existing_user)    # member of the team account only
    @home = accounts(:personal_account)
    @sharing = accounts(:team_account)
    @lume = agents(:research_assistant)   # hosted in @home
    @local = agents(:other_account_agent) # hosted in @sharing
    @seat = @sharing.guest_memberships.create!(agent: @lume, added_by: @daniel)
    @connection = google_connection(owner: @anna, scopes: [ DRIVE_READ ])
  end

  test "a grant needs the resident hosted where the connection lives, or seated there as a guest" do
    stranger = Agent.create!(account: accounts(:another_team), name: "Stranger", model_id: "openrouter/auto")
    row = AgentServiceAccess.new(agent: stranger, service_connection: @connection, enabled: true, home_approval: "pending")
    assert_not row.valid?
    assert_includes row.errors.full_messages.join, "guest"

    assert AgentServiceAccess.new(agent: @lume, service_connection: @connection, enabled: true, home_approval: "pending").valid?
    assert AgentServiceAccess.new(agent: @local, service_connection: @connection, enabled: true).valid?
  end

  test "a guest's row carries an approval state and a hosted row never does" do
    assert_not AgentServiceAccess.new(agent: @lume, service_connection: @connection, enabled: true, home_approval: "not_required").valid?
    assert_not AgentServiceAccess.new(agent: @lume, service_connection: @connection, enabled: true, home_approval: "declined").valid?
    assert_not AgentServiceAccess.new(agent: @lume, service_connection: @connection, enabled: true, home_approval: "pending", follows_default: true).valid?
    assert_not AgentServiceAccess.new(agent: @local, service_connection: @connection, enabled: true, home_approval: "pending").valid?
  end

  test "the owner's switch asks the home and grants nothing until it answers" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)

    assert access.enabled?
    assert_equal "pending", access.home_approval
    assert_equal 1, access.home_approval_generation
    assert_equal [ DRIVE_READ ], access.home_approval_authority["granted_scopes"]
    assert_not access.effective?
    assert_empty AgentServiceAccess.effective.where(id: access.id)
    assert_empty @lume.service_connections.merge(AgentServiceAccess.effective)
    assert_empty Agents::ServiceManifest.new(@lume).to_h["services"]
    assert_equal [ "requested" ], events(access).map(&:action)

    access.approve_home!(actor: @daniel, generation: 1)

    assert access.effective?
    assert_includes AgentServiceAccess.effective, access
    assert_includes @lume.service_connections.merge(AgentServiceAccess.effective), @connection
    entry = Agents::ServiceManifest.new(@lume).to_h["services"].sole
    assert_equal @connection.public_id, entry["connection_id"]
    assert_equal({ "account" => @sharing.name, "guest" => true }, entry["origin"])
    assert_equal @daniel, access.home_approval_by
    assert_equal %w[requested approved], events(access).map(&:action)
  end

  test "not_required never authorises a foreign row, and enabled alone never authorises a guest" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    access.update_columns(home_approval: "not_required")

    assert_not access.reload.effective?
    assert_empty AgentServiceAccess.effective.where(id: access.id)
    assert_empty Agents::ServiceManifest.new(@lume).to_h["services"]
  end

  test "an approval only counts while the seat is current" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    access.approve_home!(actor: @daniel, generation: 1)
    GuestMembership.where(id: @seat.id).delete_all # a seat that vanished without callbacks

    assert_not access.reload.effective?
    assert_empty AgentServiceAccess.effective.where(id: access.id)
  end

  test "a personal connection is its owner's alone to share, even where admins may provision it" do
    @connection.update!(freely_provisionable: true)

    assert_nothing_raised { @local.set_service_access!(@connection, enabled: true, actor: @daniel) }
    error = assert_raises(AgentServiceAccess::ReadGrantRefused) { @lume.set_service_access!(@connection, enabled: true, actor: @daniel) }
    assert_match(/owner/, error.message)
    assert_nil @lume.agent_service_accesses.find_by(service_connection: @connection)
  end

  test "an account-wide connection is shared by whoever can switch it on for residents" do
    shared = google_connection(owner: @anna, scopes: [ DRIVE_READ ], management_scope: "account_managed", subject: "google-team")

    access = @lume.set_service_access!(shared, enabled: true, actor: @daniel)
    assert_equal "pending", access.home_approval
  end

  test "defaults never reach guests" do
    defaulted = google_connection(owner: @anna, scopes: [ DRIVE_READ ], subject: "google-default", enabled_for_new_agents: true)

    assert defaulted.agent_service_accesses.exists?(agent: @local)
    assert_not defaulted.agent_service_accesses.exists?(agent: @lume)
  end

  test "a decision names the request it saw" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)

    assert_raises(AgentServiceAccess::HomeApprovalRefused) { access.approve_home!(actor: @daniel, generation: 0) }
    assert_equal "pending", access.reload.home_approval
    assert_raises(AgentServiceAccess::HomeApprovalRefused) { access.decline_home!(actor: @daniel, generation: 2) }
    assert_equal "pending", access.reload.home_approval
  end

  test "a change to what the connection carries sends the approval back to the home" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    access.approve_home!(actor: @daniel, generation: 1)

    # A re-auth of the same identity with the same scopes keeps it.
    @connection.update!(credential_payload_hash: @connection.credential_payload_hash.merge("refresh_token" => "fresh"))
    assert_equal "approved", access.reload.home_approval

    @connection.update!(credential_metadata: @connection.credential_metadata.merge("granted_scopes" => [ DRIVE_WRITE ]))
    access.reload
    assert_equal "pending", access.home_approval
    assert_equal 2, access.home_approval_generation
    assert_equal [ DRIVE_WRITE ], access.home_approval_authority["granted_scopes"]
    assert_not access.effective?
    assert_equal "authority_changed", events(access).last.reason

    access.approve_home!(actor: @daniel, generation: 2)
    @connection.update!(connected_by_user: @daniel)
    assert_equal "pending", access.reload.home_approval
  end

  test "a stale request is re-asked rather than approved" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    # The connection changed in a way the hook does not watch for; the
    # snapshot check at decision time still catches it.
    @connection.update_columns(external_subject_id: "google-someone-else")

    assert_raises(AgentServiceAccess::HomeApprovalRefused) { access.approve_home!(actor: @daniel, generation: 1) }
    access.reload
    assert_equal "pending", access.home_approval
    assert_equal 2, access.home_approval_generation
    assert_equal "google-someone-else", access.home_approval_authority["external_subject_id"]
  end

  test "switching off voids the approval; switching on asks again" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    access.approve_home!(actor: @daniel, generation: 1)

    @lume.set_service_access!(@connection, enabled: false, actor: @anna)
    access.reload
    assert_not access.enabled?
    assert_equal "withdrawn", access.home_approval
    assert_not access.effective?
    assert_equal "access_disabled", events(access).last.reason

    @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    access.reload
    assert_equal "pending", access.home_approval
    assert_equal 2, access.home_approval_generation
    assert_not access.effective?
  end

  test "switching on twice does not ask twice" do
    @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)

    assert_equal 1, access.home_approval_generation
    assert_equal 1, events(access).count
  end

  test "the home revokes, and the sharing side cannot restore it without a new approval" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    access.approve_home!(actor: @daniel, generation: 1)

    access.revoke_home!(actor: @daniel)
    access.reload
    assert_not access.enabled?
    assert_equal "revoked", access.home_approval
    assert_empty Agents::ServiceManifest.new(@lume).to_h["services"]

    @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    access.reload
    assert_equal "pending", access.home_approval
    assert_not access.effective?
  end

  test "declining switches it off and the sharing side can ask again" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    access.decline_home!(actor: @daniel, generation: 1)
    access.reload
    assert_not access.enabled?
    assert_equal "declined", access.home_approval

    @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    assert_equal "pending", access.reload.home_approval
  end

  test "leaving the account ends every grant, approved or pending" do
    approved = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    approved.approve_home!(actor: @daniel, generation: 1)
    pending = @lume.set_service_access!(google_connection(owner: @anna, scopes: [ DRIVE_READ ], subject: "google-two"), enabled: true, actor: @anna)

    @seat.destroy!

    assert_not AgentServiceAccess.exists?(approved.id)
    assert_not AgentServiceAccess.exists?(pending.id)
    assert_equal %w[guest_left guest_left], GuestAccessApprovalEvent.where(agent: @lume, action: "guest_left").pluck(:action)
  end

  test "a request expires on its own clock, not on updated_at" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    access.update_columns(home_approval_requested_at: 15.days.ago, updated_at: Time.current)
    fresh = @lume.set_service_access!(google_connection(owner: @anna, scopes: [ DRIVE_READ ], subject: "google-fresh"), enabled: true, actor: @anna)

    GuestAccessRequestSweepJob.perform_now

    access.reload
    assert_equal "expired", access.home_approval
    assert_not access.enabled?
    assert_equal "pending", fresh.reload.home_approval
  end

  test "an expired request is refused at decision time before any sweeper runs" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    access.update_columns(home_approval_requested_at: 15.days.ago)

    assert_raises(AgentServiceAccess::HomeApprovalRefused) { access.approve_home!(actor: @daniel, generation: 1) }
    assert_equal "expired", access.reload.home_approval
  end

  test "a resident's own key cannot grant itself a guest connection" do
    assert_raises(ActiveRecord::RecordNotFound) do
      @lume.set_service_access!(@connection, enabled: true, actor: @anna, resident_actor: @lume)
    end
  end

  test "an approval change reconciles the resident's manifest like a switch does" do
    @lume.update!(runtime: "external", container_name: "test-lume-container")
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    clear_enqueued_jobs

    assert_enqueued_with(job: AccountAgentCredentialsRefreshJob, args: [ @home.id, @lume.id, { manifest_only: true } ]) do
      access.approve_home!(actor: @daniel, generation: 1)
    end
  end

  test "hosted rows are untouched" do
    access = @local.set_service_access!(@connection, enabled: true, actor: @anna)

    assert_equal "not_required", access.home_approval
    assert access.effective?
    assert_includes AgentServiceAccess.effective, access
  end

  test "waiting requests are counted for the home's owners only" do
    @lume.set_service_access!(@connection, enabled: true, actor: @anna)

    summary = ExpiredProviderSubscriptions.summary_for(@daniel)
    item = summary[:awaiting].sole
    assert_equal @lume.name, item[:agent_name]
    assert_equal @sharing.name, item[:sharing_account_name]
    assert_equal 1, summary[:total]

    assert_empty ExpiredProviderSubscriptions.summary_for(@anna)[:awaiting]
  end

  test "a request arriving or being decided refreshes the home owners' notice live" do
    stream = "Account:#{@home.obfuscated_id}"
    marker = { action: "refresh", prop: "expired_subscriptions" }

    access = nil
    assert_broadcast_on(stream, marker) do
      access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    end
    assert_equal "pending", access.home_approval

    assert_broadcast_on(stream, marker) do
      access.approve_home!(actor: @daniel, generation: access.home_approval_generation)
    end
  end

  test "a waiting request removed with the guest's seat or its connection clears the home owners' notice live" do
    stream = "Account:#{@home.obfuscated_id}"
    marker = { action: "refresh", prop: "expired_subscriptions" }
    @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    other = google_connection(owner: @anna, scopes: [ DRIVE_READ ], subject: "google-two")
    @lume.set_service_access!(other, enabled: true, actor: @anna)

    assert_broadcast_on(stream, marker) { other.destroy! }
    assert_equal 1, ExpiredProviderSubscriptions.summary_for(@daniel)[:awaiting].size

    assert_broadcast_on(stream, marker) { @seat.destroy! }
    assert_empty ExpiredProviderSubscriptions.summary_for(@daniel)[:awaiting]
  end

  test "a hosted grant sends no approval notice" do
    assert_no_broadcasts("Account:#{@sharing.obfuscated_id}") do
      @local.set_service_access!(@connection, enabled: true, actor: @anna)
    end
  end

  private

  def events(access)
    GuestAccessApprovalEvent.where(agent_id: access.agent_id, service_connection_id: access.service_connection_id).order(:id)
  end

  def google_connection(owner:, scopes:, management_scope: "personal", subject: "google-anna", enabled_for_new_agents: false)
    @sharing.service_connections.create!(
      connected_by_user: owner,
      provider: "google_workspace",
      external_subject_id: subject,
      external_identity: "#{subject}@example.test",
      management_scope: management_scope,
      credential_kind: "oauth2",
      enabled_for_new_agents: enabled_for_new_agents,
      credential_payload_hash: { "access_token" => "anna-access", "refresh_token" => "anna-refresh", "expires_at" => 2.days.from_now.utc.iso8601 },
      credential_metadata: { "credential_strategy" => "refresh_broker", "granted_scopes" => scopes }
    )
  end

end
