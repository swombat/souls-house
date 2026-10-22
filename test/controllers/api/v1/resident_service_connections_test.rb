require "test_helper"

# Issue #500: a resident sets up a pasted-credentials service itself, grants
# it, and every change is a notice in the room it was asked in, not a gate.
module Api
  module V1
    class ResidentServiceConnectionsTest < ActionDispatch::IntegrationTest

      KEY = "6489f0c2a1b2c3d4e5f60718:#{'ab' * 32}".freeze

      setup do
        @daniel = users(:confirmed_user)
        @account = @daniel.personal_account
        @lume = @account.agents.create!(name: "Lume", system_prompt: "Test", runtime: "external")
        @mira = @account.agents.create!(name: "Mira", system_prompt: "Test", runtime: "external")
        @chat = @account.chats.new(model_id: "openrouter/auto", title: "Blog", manual_responses: true)
        @chat.agents = [ @lume, @mira ]
        @chat.save!
        @lume_headers = auth(ApiKey.generate_for(@daniel, name: "Lume", agent: @lume))
        @mira_headers = auth(ApiKey.generate_for(@daniel, name: "Mira", agent: @mira))
        @human_headers = auth(ApiKey.generate_for(@daniel, name: "Daniel", account: @account))
        @ghost = Services::Definition.fetch("ghost")
        @fingerprints = 0
      end

      def auth(key) = { "Authorization" => "Bearer #{key.raw_token}" }

      def fake_adapter
        test = self
        adapter = Object.new
        adapter.define_singleton_method(:connection_attributes) do |credentials:, user:|
          test.instance_variable_set(:@fingerprints, test.instance_variable_get(:@fingerprints) + 1)
          raise Services::AdapterError, "Ghost Admin API key is required" if credentials["admin_api_key"].blank?

          {
            external_subject_id: "blog.example.com:6489f0c2a1b2c3d4e5f60718",
            external_identity: "https://blog.example.com",
            label: "Ghost (Lume writes)",
            credential_kind: "token",
            credential_fingerprint: "fp-#{test.instance_variable_get(:@fingerprints)}",
            credential_payload: { "admin_api_key" => credentials["admin_api_key"] },
            credential_metadata: { "credential_strategy" => "static", "authority_summary" => "Writes to Lume writes." }
          }
        end
        adapter.define_singleton_method(:revoke) { |_connection| true }
        adapter
      end

      def connect(headers: @lume_headers, **extra)
        @ghost.stub :adapter, fake_adapter do
          post api_v1_resident_service_connections_path,
               params: { provider: "ghost", conversation_id: @chat.to_param,
                         credentials: { api_url: "https://blog.example.com", admin_api_key: KEY } }.merge(extra),
               headers: headers, as: :json
        end
        response.media_type == "application/json" ? response.parsed_body.dig("service_connection", "id") : nil
      end

      def notices = @chat.messages.where(role: "system").order(:id)

      test "a resident connects Ghost for its person, grants it to itself, and says so in the room with a way to undo" do
        id = connect

        assert_response :created
        connection = ServiceConnection.find_by_public_id!(id)
        assert_equal [ @lume, @daniel, "personal" ], [ connection.connected_by_agent, connection.connected_by_user, connection.management_scope ]
        assert_equal "Lume for #{@daniel.display_name}", response.parsed_body.dig("service_connection", "connected_by_name")
        assert_equal [ "Lume" ], response.parsed_body.dig("service_connection", "residents").map { |r| r["name"] }
        assert connection.agent_service_accesses.enabled.exists?(agent: @lume)
        assert_not_includes response.body, KEY

        notice = notices.sole
        assert_match "Lume connected Ghost (Lume writes) for #{@daniel.display_name}.", notice.content
        assert_match "Residents who can use it: Lume.", notice.content
        assert_match "stays valid at Ghost until it is rotated or deleted there", notice.content
        assert_equal({ "label" => "Integrations", "path" => "/accounts/#{@account.to_param}/integrations" }, notice.notice_link)
        assert_not_includes notice.content, KEY

        log = AuditLog.find_by!(action: "connect_service", auditable: connection)
        assert_equal [ @lume.id, "resident" ], [ log.data["agent_id"], log.data["actor"] ]
      end

      test "if the notice can't be written, nothing is connected, granted or disconnected" do
        failing = ->(*) { raise ActiveRecord::RecordNotSaved, "notice failed" }

        ResidentConnectionNotice.stub(:post!, failing) { connect }
        assert_not response.successful?, response.status.to_s
        assert_equal 0, ServiceConnection.where(connected_by_agent: @lume).count
        assert_equal 0, AgentServiceAccess.where(agent: @lume).count
        assert_not AuditLog.exists?(action: "connect_service")

        id = connect
        ResidentConnectionNotice.stub(:post!, failing) do
          patch resident_access_api_v1_resident_service_connection_path(id, resident_id: @mira.to_param),
                params: { enabled: true, conversation_id: @chat.to_param }, headers: @lume_headers, as: :json
          assert_not response.successful?, response.status.to_s
          @ghost.stub(:adapter, fake_adapter) do
            delete api_v1_resident_service_connection_path(id), params: { conversation_id: @chat.to_param }, headers: @lume_headers, as: :json
          end
          assert_not response.successful?, response.status.to_s
        end
        connection = ServiceConnection.find_by_public_id!(id)
        assert_equal "connected", connection.status
        assert_not connection.agent_service_accesses.exists?(agent: @mira)
      end

      test "grants another home resident, withdraws, and both appear in the room" do
        id = connect

        patch resident_access_api_v1_resident_service_connection_path(id, resident_id: @mira.to_param),
              params: { enabled: true, conversation_id: @chat.to_param }, headers: @lume_headers, as: :json
        assert_response :success
        assert_equal %w[Lume Mira], response.parsed_body.dig("service_connection", "residents").map { |r| r["name"] }.sort
        assert_match "Lume gave Mira access to Ghost (Lume writes). Residents who can use it: Lume, Mira.", notices.last.content

        patch resident_access_api_v1_resident_service_connection_path(id, resident_id: @mira.to_param),
              params: { enabled: false, conversation_id: @chat.to_param }, headers: @lume_headers, as: :json
        assert_response :success
        assert_match "Lume removed Mira's access", notices.last.content
        assert AuditLog.exists?(action: "disable_resident_service")
      end

      test "the resident disconnects what it made, and the room is told the key still works at Ghost" do
        id = connect
        @ghost.stub :adapter, fake_adapter do
          delete api_v1_resident_service_connection_path(id), params: { conversation_id: @chat.to_param }, headers: @lume_headers, as: :json
        end

        assert_response :success
        assert_match "until it is rotated or deleted there", response.parsed_body["provider_side"]
        assert_not ServiceConnection.where(connected_by_agent: @lume).exists?
        assert_match "Lume disconnected Ghost (Lume writes).", notices.last.content
        assert_match "anything already done with it stays done", notices.last.content
      end

      test "a person disconnects a resident-made connection from the web, as owner" do
        connection = ServiceConnection.find_by_public_id!(connect)
        sign_in @daniel

        @ghost.stub :adapter, fake_adapter do
          delete account_service_connection_path(@account, connection.public_id)
        end

        assert_response :redirect
        assert_not ServiceConnection.exists?(connection.id)
      end

      test "the represented person is the key's own person: nothing in the request can choose another" do
        other = users(:existing_user)
        id = connect(user_id: other.id, for: other.id, connected_by_user_id: other.id)

        assert_response :created
        assert_equal @daniel, ServiceConnection.find_by_public_id!(id).connected_by_user
      end

      test "scope is always personal; account-managed, delegation and new-resident defaults can't be asked for" do
        id = connect(management_scope: "account_managed", freely_provisionable: true, enabled_for_new_agents: true)

        connection = ServiceConnection.find_by_public_id!(id)
        assert_equal [ "personal", false, false ], [ connection.management_scope, connection.freely_provisionable?, connection.enabled_for_new_agents? ]

        patch api_v1_resident_service_connection_path(id), params: { label: "Blog", freely_provisionable: true, management_scope: "account_managed" },
                                                           headers: @lume_headers, as: :json
        assert_response :success
        assert_equal [ "Blog", "personal", false ], [ connection.reload.label, connection.management_scope, connection.freely_provisionable? ]
      end

      test "home account only: a guest or other account_id is 404" do
        guest_account = accounts(:team_account)
        GuestMembership.new(account: guest_account, agent: @lume).save!(validate: false)

        connect(account_id: guest_account.to_param)
        assert_response :not_found
        get api_v1_resident_service_connections_path, params: { account_id: accounts(:another_team).to_param }, headers: @lume_headers
        assert_response :not_found
        assert_equal 0, ServiceConnection.where(connected_by_agent: @lume).count
      end

      test "a resident can't touch connections it didn't make: a person's own, OAuth, or another resident's" do
        persons = @account.service_connections.create!(connected_by_user: @daniel, provider: "ghost", management_scope: "personal",
                                                       credential_kind: "token", credential_fingerprint: "persons", label: "Daniel's blog")
        oauth = @account.service_connections.create!(connected_by_user: @daniel, connected_by_agent: @lume, provider: "dropbox",
                                                     management_scope: "personal", credential_kind: "oauth", credential_fingerprint: "dbx")
        miras = ServiceConnection.find_by_public_id!(connect(headers: @mira_headers))

        [ persons, oauth, miras ].each do |connection|
          patch api_v1_resident_service_connection_path(connection.public_id), params: { label: "Mine now" }, headers: @lume_headers, as: :json
          assert_response :not_found, connection.provider
          patch resident_access_api_v1_resident_service_connection_path(connection.public_id, resident_id: @lume.to_param),
                params: { enabled: true, conversation_id: @chat.to_param }, headers: @lume_headers, as: :json
          assert_response :not_found, connection.provider
          delete api_v1_resident_service_connection_path(connection.public_id), params: { conversation_id: @chat.to_param }, headers: @lume_headers, as: :json
          assert_response :not_found, connection.provider
          assert ServiceConnection.exists?(connection.id)
          assert_not_equal "Mine now", connection.reload.label
        end

        get api_v1_resident_service_connections_path, headers: @lume_headers
        assert_empty response.parsed_body["service_connections"].map { |c| c["id"] } & [ persons, miras ].map(&:public_id)
      end

      test "grants only reach residents of the same home account" do
        id = connect
        patch resident_access_api_v1_resident_service_connection_path(id, resident_id: agents(:other_account_agent).to_param),
              params: { enabled: true, conversation_id: @chat.to_param }, headers: @lume_headers, as: :json

        assert_response :not_found
        assert_not AgentServiceAccess.exists?(agent: agents(:other_account_agent))
      end

      test "OAuth, pairing and sign-in services stay with people" do
        %w[dropbox google_workspace tailscale].each do |provider|
          post api_v1_resident_service_connections_path, params: { provider:, conversation_id: @chat.to_param, credentials: { x: "y" } },
                                                         headers: @lume_headers, as: :json
          assert_response :unprocessable_entity, provider
        end
        get providers_api_v1_resident_service_connections_path, headers: @lume_headers
        keys = response.parsed_body["providers"].map { |p| p["key"] }
        assert_includes keys, "ghost"
        assert_empty keys & %w[dropbox google_workspace tailscale whatsapp telegram twitterapi_io]
      end

      test "a notice is required: no conversation, or one the resident isn't in, means nothing is connected" do
        connect(conversation_id: nil)
        assert_response :unprocessable_entity

        elsewhere = @account.chats.create!(model_id: "openrouter/auto", title: "Not Lume's")
        connect(conversation_id: elsewhere.to_param)
        assert_response :not_found
        assert_equal 0, ServiceConnection.where(connected_by_agent: @lume).count
      end

      test "a person's key is refused here, and the person's own endpoints still refuse resident keys" do
        connect(headers: @human_headers)
        assert_response :forbidden

        post api_v1_account_service_connections_path, params: { provider: "ghost", credentials: { admin_api_key: KEY } }, headers: @lume_headers, as: :json
        assert_response :forbidden
      end

      test "a key whose person has left the account can't connect on their behalf" do
        @account.memberships.where(user: @daniel).delete_all
        connect

        assert_response :forbidden
        assert_equal 0, ServiceConnection.where(connected_by_agent: @lume).count
      end

    end
  end
end
