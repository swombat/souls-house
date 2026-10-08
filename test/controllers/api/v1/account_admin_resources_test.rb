require "test_helper"

module Api
  module V1
    # Visual tags, guest residents, service connections and model provider
    # keys, with a person's key.
    class AccountAdminResourcesTest < ActionDispatch::IntegrationTest

      setup do
        @daniel = users(:user_1)
        @home = accounts(:personal_account)
        @nexus = accounts(:team_account)
        @lume = agents(:research_assistant)
        @home_headers = headers_for(ApiKey.generate_for(@daniel, name: "Home agent", account: @home))
        @nexus_owner_headers = headers_for(ApiKey.generate_for(@daniel, name: "Nexus agent", account: @nexus))
        @nexus_member_headers = headers_for(ApiKey.generate_for(users(:existing_user), name: "Member agent", account: @nexus))
        @resident_headers = headers_for(ApiKey.generate_for(@daniel, name: "Resident", agent: @lume))
        Setting.instance.update!(allow_agents: true)
      end

      # Visual tags

      test "creates, edits and removes visual tags with the web's audit entries" do
        post api_v1_account_visual_tags_path, params: { label: "Ops", icon: "Heart", colour: "teal" }, headers: @home_headers, as: :json
        assert_response :created
        tag = @home.visual_tags.find_by!(label: "Ops")
        assert_equal tag.as_json, response.parsed_body["visual_tag"]
        assert AuditLog.exists?(action: "create_visual_tag", auditable: tag)

        patch api_v1_account_visual_tag_path(tag), params: { label: "Operations" }, headers: @home_headers, as: :json
        assert_response :success
        assert_equal "Operations", tag.reload.label
        assert_equal [ "Ops", "Operations" ], AuditLog.find_by!(action: "update_visual_tag").data["label"]

        delete api_v1_account_visual_tag_path(tag), headers: @home_headers
        assert_response :success
        assert_not VisualTag.exists?(tag.id)
        assert AuditLog.exists?(action: "destroy_visual_tag")
      end

      test "visual tag validation, the fixed Pin, other accounts and residents" do
        post api_v1_account_visual_tags_path, params: { label: "Ops", icon: "Heart", colour: "neon" }, headers: @home_headers, as: :json
        assert_response :unprocessable_entity
        assert response.parsed_body.dig("errors", "colour").present?

        pin = @home.visual_tags.create!(**VisualTag::PIN, pinned: true)
        delete api_v1_account_visual_tag_path(pin), headers: @home_headers
        assert_response :unprocessable_entity
        assert VisualTag.exists?(pin.id)

        theirs = @nexus.visual_tags.create!(label: "Theirs", icon: "Heart", colour: "teal")
        delete api_v1_account_visual_tag_path(theirs), headers: @home_headers
        assert_response :not_found

        post api_v1_account_visual_tags_path, params: { label: "Sneaky", icon: "Heart", colour: "teal" }, headers: @resident_headers, as: :json
        assert_response :forbidden
        assert_not @home.visual_tags.exists?(label: "Sneaky")
      end

      # Guest residents

      test "someone in both accounts adds a guest, and lists guests and candidates" do
        get api_v1_account_guest_memberships_path, headers: @nexus_owner_headers
        assert_response :success
        assert_includes response.parsed_body["candidates"].map { |candidate| candidate["name"] }, @lume.name

        assert_difference -> { @nexus.guest_memberships.count }, 1 do
          post api_v1_account_guest_memberships_path, params: { agent_id: @lume.to_param }, headers: @nexus_owner_headers, as: :json
        end
        assert_response :created
        membership = @nexus.guest_memberships.last
        assert_equal @daniel, membership.added_by
        assert AuditLog.exists?(action: "add_guest_resident", auditable: membership)

        get api_v1_account_guest_memberships_path, headers: @home_headers
        assert_equal [ membership.to_param ], response.parsed_body["away"].map { |item| item["id"] }
      end

      test "someone outside the resident's home cannot add it, and only an owner removes a guest" do
        assert_no_difference -> { GuestMembership.count } do
          post api_v1_account_guest_memberships_path, params: { agent_id: @lume.to_param }, headers: @nexus_member_headers, as: :json
        end
        assert_response :unprocessable_entity

        membership = @nexus.guest_memberships.create!(agent: @lume, added_by: @daniel)
        delete api_v1_account_guest_membership_path(membership), headers: @nexus_member_headers
        assert_response :forbidden
        assert GuestMembership.exists?(membership.id)

        delete api_v1_account_guest_membership_path(membership), headers: @home_headers
        assert_response :success, "the hosting account's owner may withdraw its resident"
        assert_not GuestMembership.exists?(membership.id)
        assert AuditLog.exists?(action: "remove_guest_resident")
      end

      test "guest memberships elsewhere are not found" do
        elsewhere = accounts(:another_team).guest_memberships.create!(agent: agents(:other_account_agent), added_by: users(:existing_user))
        delete api_v1_account_guest_membership_path(elsewhere), headers: @home_headers
        assert_response :not_found
      end

      # Service connections

      test "lists, relabels, toggles and disconnects your own connection" do
        connection = create_connection(account: @nexus, user: @daniel)

        get api_v1_account_service_connections_path, headers: @nexus_owner_headers
        assert_response :success
        listed = response.parsed_body["service_connections"]
        assert_equal [ connection.public_id ], listed.map { |item| item["id"] }
        assert_not_includes response.body, "github_pat_secret"

        patch api_v1_account_service_connection_path(connection.public_id),
          params: { label: "Site repo", enabled_for_new_agents: true, freely_provisionable: true },
          headers: @nexus_owner_headers, as: :json
        assert_response :success
        connection.reload
        assert_equal "Site repo", connection.label
        assert connection.enabled_for_new_agents?
        assert connection.freely_provisionable?
        assert AuditLog.exists?(action: "update_service_connection", auditable: connection)

        delete api_v1_account_service_connection_path(connection.public_id), headers: @nexus_owner_headers
        assert_response :success
        assert_not ServiceConnection.exists?(connection.id)
        assert AuditLog.exists?(action: "disconnect_service")
      end

      test "someone else's personal connection can't be managed by a member" do
        connection = create_connection(account: @nexus, user: @daniel)

        get api_v1_account_service_connections_path, headers: @nexus_member_headers
        assert_equal [], response.parsed_body["service_connections"]

        patch api_v1_account_service_connection_path(connection.public_id), params: { label: "Mine now" }, headers: @nexus_member_headers, as: :json
        assert_response :forbidden
        delete api_v1_account_service_connection_path(connection.public_id), headers: @nexus_member_headers
        assert_response :forbidden
        assert_equal "owner/repository", connection.reload.label

        patch api_v1_account_service_connection_path(connection.public_id), params: { label: "Elsewhere" }, headers: @home_headers, as: :json
        assert_response :not_found
      end

      # Model provider keys

      test "the read says only which providers are set" do
        @home.update!(anthropic_api_key: "sk-ant-secret-value")

        get api_v1_account_ai_provider_keys_path, headers: @home_headers
        assert_response :success
        assert_equal true, response.parsed_body.dig("ai_api_keys_configured", "anthropic")
        assert_equal false, response.parsed_body.dig("ai_api_keys_configured", "openai")
        assert_not_includes response.body, "sk-ant-secret-value"
      end

      test "an owner sets and clears provider keys, write-only, with a filtered audit entry" do
        @home.update!(openai_api_key: "sk-old-openai")

        assert_enqueued_with(job: AccountAgentCredentialsRefreshJob, args: [ @home.id ]) do
          patch api_v1_account_ai_provider_keys_path,
            params: { set: { anthropic: "sk-ant-new-value" }, clear: [ "openai" ] }, headers: @home_headers, as: :json
        end

        assert_response :success
        assert_not_includes response.body, "sk-ant-new-value"
        @home.reload
        assert_equal "sk-ant-new-value", @home.anthropic_api_key
        assert_nil @home.openai_api_key
        log = AuditLog.find_by!(action: "update_agent_api_keys")
        assert_not_includes log.data.to_json, "sk-ant-new-value"
        assert_not_includes log.data.to_json, "sk-old-openai"
      end

      test "provider keys need an owner or admin, known providers, and a human key" do
        patch api_v1_account_ai_provider_keys_path, params: { set: { anthropic: "sk-member" } }, headers: @nexus_member_headers, as: :json
        assert_response :forbidden
        assert_nil @nexus.reload.anthropic_api_key

        patch api_v1_account_ai_provider_keys_path, params: { set: { skynet: "sk-x" } }, headers: @home_headers, as: :json
        assert_response :unprocessable_entity

        patch api_v1_account_ai_provider_keys_path, params: { set: { anthropic: "sk-resident" } }, headers: @resident_headers, as: :json
        assert_response :forbidden
        assert_nil @home.reload.anthropic_api_key
      end

      private

      def headers_for(key)
        { "Authorization" => "Bearer #{key.raw_token}" }
      end

      def create_connection(account:, user:)
        account.service_connections.create!(
          connected_by_user: user,
          provider: "github",
          external_subject_id: "github-user-api-admin",
          external_identity: "owner",
          label: "owner/repository",
          management_scope: "personal",
          credential_kind: "token",
          credential_fingerprint: "api-admin-fingerprint",
          credential_payload_hash: { "token" => "github_pat_secret" },
          credential_metadata: { "credential_strategy" => "static", "repository" => "owner/repository" }
        )
      end

    end
  end
end
