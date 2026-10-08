require "test_helper"
require "support/app_oauth_test_helper"

module Api
  module V1
    class ResidentsControllerTest < ActionDispatch::IntegrationTest

      include AppOauthTestHelper

      setup do
        Setting.instance.update!(allow_agents: true)
        @user = users(:user_1)
        @account = accounts(:personal_account)
        @agent = agents(:research_assistant)
        @agent.update_columns(runtime: "deprecated")
        @token = ApiKey.generate_for(@user, name: "Residents", account: @account).raw_token
      end

      test "requires a key" do
        get api_v1_resident_url(@agent)
        assert_response :unauthorized
      end

      test "catalogue lists grouped models and the option lists" do
        get catalogue_api_v1_residents_url, headers: auth
        assert_response :success
        assert_kind_of Hash, json["grouped_models"]
        models = json["grouped_models"].values.flatten
        assert models.any?
        assert models.all? { |m| m.key?("model_id") && m.key?("label") && m.key?("reasoning") }
        assert_equal Agent::REASONING_EFFORTS, json["reasoning_efforts"]
        assert_equal Agent::VALID_COLOURS, json["colour_options"]
        assert_equal Agent::VALID_ICONS, json["icon_options"]
        assert json["default_model_id"].present?
      end

      test "shows full settings without secrets" do
        @agent.update!(telegram_bot_token: "123:secret-bot-token", telegram_bot_username: "research_bot")
        get api_v1_resident_url(@agent), headers: auth
        assert_response :success
        agent = json["agent"]
        assert_equal "Research Assistant", agent["name"]
        assert_equal true, agent["telegram_configured"]
        assert agent.key?("reasoning_effort")
        assert agent.key?("session_context_budget_tokens")
        assert json.key?("subagent_catalog")
        assert json.key?("service_connections")
        assert json.key?("provisioning")
        assert_not_includes response.body, "secret-bot-token"
        Agent::SENSITIVE_JSON_ATTRIBUTES.each { |attribute| assert_not agent.key?(attribute.to_s) }
        assert_not json.key?("telegram_deep_link")
      end

      test "another account's resident is not found" do
        get api_v1_resident_url(agents(:other_account_agent)), headers: auth
        assert_response :not_found
        patch api_v1_resident_url(agents(:other_account_agent)), params: { agent: { name: "Mine now" } }, headers: auth, as: :json
        assert_response :not_found
        assert_equal "Team Agent", agents(:other_account_agent).reload.name
      end

      test "a key whose person is no longer a member of its account is not found" do
        token = ApiKey.generate_for(users(:existing_user), name: "Stale", account: @account).raw_token
        get api_v1_resident_url(@agent), headers: auth(token)
        assert_response :not_found
        get catalogue_api_v1_residents_url, headers: auth(token)
        assert_response :not_found
      end

      # Mira, #234: Account#accessible_by? ignores disablement, so a member's
      # key kept working after the account was disabled.
      test "a disabled account's key is not found, for reads and writes" do
        connection = service_connection(@account, @user)
        @account.update_columns(disabled_at: Time.current)

        get api_v1_resident_url(@agent), headers: auth
        assert_response :not_found
        get catalogue_api_v1_residents_url, headers: auth
        assert_response :not_found
        get provisioning_api_v1_resident_url(@agent), headers: auth
        assert_response :not_found
        patch api_v1_resident_url(@agent), params: { agent: { name: "After closing" } }, headers: auth, as: :json
        assert_response :not_found
        delete api_v1_resident_url(@agent), headers: auth
        assert_response :not_found
        assert_no_difference [ "Agent.count", "AgentServiceAccess.count" ] do
          post api_v1_residents_url, params: { agent: { name: "Late", system_prompt: "x" } }, headers: auth, as: :json
          assert_response :not_found
          patch service_access_api_v1_resident_url(@agent, connection_id: connection.public_id),
                headers: auth, as: :json, params: { enabled: true }
          assert_response :not_found
        end
        @agent.reload
        assert_equal "Research Assistant", @agent.name
        assert @agent.active?
      end

      # OAuth: a person's token spans their enabled accounts. The resident's
      # own account decides authority, and audit rows carry the app session.
      test "oauth: reads and edits a resident in a second account without account_id" do
        oauth_setup
        get api_v1_resident_url(@team_agent), headers: bearer(@tokens)
        assert_response :success
        assert_equal "Team Agent", json.dig("agent", "name")

        patch api_v1_resident_url(@team_agent), params: { agent: { name: "Team Renamed" } }, headers: bearer(@tokens), as: :json
        assert_response :success
        assert_equal "Team Renamed", @team_agent.reload.name
        log = AuditLog.where(action: "update_agent", auditable: @team_agent).last
        assert_equal @team, log.account
        assert_equal users(:existing_user), log.user
        assert_equal @app_session.id, log.data["app_session_id"]
        assert_not log.data.key?("api_key_id")
      end

      test "oauth: service access and birth in a named account audit the app session and that account" do
        oauth_setup
        connection = service_connection(@team, users(:existing_user))
        patch service_access_api_v1_resident_url(@team_agent, connection_id: connection.public_id),
              headers: bearer(@tokens), as: :json, params: { enabled: true }
        assert_response :success
        log = AuditLog.where(action: "enable_resident_service").last
        assert_equal @team, log.account
        assert_equal @app_session.id, log.data["app_session_id"]

        post api_v1_residents_url, headers: bearer(@tokens), as: :json, params: {
          account_id: @team.to_param, agent: { name: "OAuth Birth", system_prompt: "Be kind", model_id: "openrouter/auto" }
        }
        assert_response :created
        born = Agent.find_by!(name: "OAuth Birth")
        assert_equal @team, born.account
        log = AuditLog.where(action: "create_agent", auditable: born).last
        assert_equal @team, log.account
        assert_equal @app_session.id, log.data["app_session_id"]
      end

      test "oauth: account_id naming another of the person's accounts does not reach the resident" do
        oauth_setup
        get api_v1_resident_url(@team_agent, account_id: accounts(:another_team).to_param), headers: bearer(@tokens)
        assert_response :not_found
        patch api_v1_resident_url(@team_agent, account_id: accounts(:another_team).to_param),
              params: { agent: { name: "Wrong door" } }, headers: bearer(@tokens), as: :json
        assert_response :not_found
        assert_equal "Team Agent", @team_agent.reload.name

        get api_v1_resident_url(@team_agent, account_id: @team.to_param), headers: bearer(@tokens)
        assert_response :success
      end

      test "oauth: a resident outside the person's accounts is not found" do
        oauth_setup
        get api_v1_resident_url(@agent), headers: bearer(@tokens)
        assert_response :not_found
      end

      # Mira, #232 approval: human_account! checks membership only. A key
      # minted for account A must not reach a resident in account B, even
      # though its person belongs to both.
      test "a key for one of the person's accounts does not reach a resident in another of them" do
        person = users(:existing_user)
        team_agent = agents(:other_account_agent)
        connection = service_connection(accounts(:team_account), person)
        token = ApiKey.generate_for(person, name: "Personal", account: accounts(:existing_user_account)).raw_token

        get api_v1_resident_url(team_agent), headers: auth(token)
        assert_response :not_found
        get api_v1_resident_url(team_agent, account_id: accounts(:team_account).to_param), headers: auth(token)
        assert_response :not_found
        patch api_v1_resident_url(team_agent), params: { agent: { name: "Wrong key" } }, headers: auth(token), as: :json
        assert_response :not_found
        delete api_v1_resident_url(team_agent), headers: auth(token)
        assert_response :not_found
        assert_no_difference [ "Agent.count", "AgentServiceAccess.count" ] do
          patch service_access_api_v1_resident_url(team_agent, connection_id: connection.public_id),
                headers: auth(token), as: :json, params: { enabled: true }
          assert_response :not_found
          post api_v1_residents_url, headers: auth(token), as: :json,
               params: { account_id: accounts(:team_account).to_param, agent: { name: "Wrong door", system_prompt: "x" } }
          assert_response :not_found
        end
        team_agent.reload
        assert_equal "Team Agent", team_agent.name
        assert team_agent.active?
      end

      test "oauth: a disabled account is not found" do
        oauth_setup
        @team.update_columns(disabled_at: Time.current)
        get api_v1_resident_url(@team_agent), headers: bearer(@tokens)
        assert_response :not_found
        patch api_v1_resident_url(@team_agent), params: { agent: { name: "Closed" } }, headers: bearer(@tokens), as: :json
        assert_response :not_found
        post api_v1_residents_url, headers: bearer(@tokens), as: :json,
             params: { account_id: @team.to_param, agent: { name: "Closed Birth", system_prompt: "x" } }
        assert_response :not_found
        assert_equal "Team Agent", @team_agent.reload.name
      end

      test "oauth: a departed member is not found" do
        oauth_setup
        memberships(:team_member).destroy!
        get api_v1_resident_url(@team_agent), headers: bearer(@tokens)
        assert_response :not_found
        patch api_v1_resident_url(@team_agent), params: { agent: { name: "Gone" } }, headers: bearer(@tokens), as: :json
        assert_response :not_found
        assert_equal "Team Agent", @team_agent.reload.name
      end

      test "oauth: catalogue uses the person's default account" do
        oauth_setup
        get catalogue_api_v1_residents_url, headers: bearer(@tokens)
        assert_response :success
        assert json["default_model_id"].present?
      end

      test "resident keys are refused" do
        @agent.update_columns(runtime: "external")
        token = ApiKey.generate_for(@user, name: "Resident", agent: @agent).raw_token
        get api_v1_resident_url(@agent), headers: auth(token)
        assert_response :forbidden
        patch api_v1_resident_url(@agent), params: { agent: { name: "Self rename" } }, headers: auth(token), as: :json
        assert_response :forbidden
        post api_v1_residents_url, params: { agent: { name: "Child", system_prompt: "x" } }, headers: auth(token), as: :json
        assert_response :forbidden
        assert_equal "Research Assistant", @agent.reload.name
      end

      test "refused while residents are switched off" do
        Setting.instance.update!(allow_agents: false)
        get api_v1_resident_url(@agent), headers: auth
        assert_response :forbidden
      end

      test "births a hosted resident and reports provisioning" do
        assert_difference [ "Agent.count", "ApiKey.count" ], 1 do
          assert_enqueued_with(job: ProvisionAgentJob) do
            post api_v1_residents_url, headers: auth, as: :json, params: {
              agent: { name: "API Birth", system_prompt: "You are helpful", model_id: "openrouter/auto", colour: "teal" }
            }
          end
        end
        assert_response :created
        agent = Agent.find_by!(name: "API Birth")
        assert_equal @account, agent.account
        assert_predicate agent, :born_hosted?
        assert_equal agent.to_param, json.dig("agent", "id")
        assert_equal "provisioning", json.dig("provisioning", "state")
        assert_equal true, json.dig("provisioning", "stages", "beginning_recorded")
        assert_equal true, json.dig("provisioning", "can_retry_provisioning")
        log = AuditLog.where(action: "create_agent").last
        assert_equal @user, log.user
        assert_equal agent, log.auditable

        get provisioning_api_v1_resident_url(agent), headers: auth
        assert_response :success
        assert_equal "provisioning", json.dig("provisioning", "state")
        assert_equal false, json.dig("provisioning", "settled")
      end

      test "birth needs a soul seed unless open beginning is explicit" do
        assert_no_difference "Agent.count" do
          post api_v1_residents_url, headers: auth, as: :json, params: { agent: { name: "Blank", system_prompt: "" } }
        end
        assert_response :unprocessable_entity
        assert json.dig("errors", "system_prompt").present?

        assert_difference "Agent.count", 1 do
          post api_v1_residents_url, headers: auth, as: :json,
               params: { agent: { name: "Open", system_prompt: "", model_id: "openrouter/auto", open_beginning: true } }
        end
        assert_response :created
      end

      test "birth validation failure" do
        post api_v1_residents_url, headers: auth, as: :json, params: { agent: { name: "", system_prompt: "x" } }
        assert_response :unprocessable_entity
        assert json.dig("errors", "name").present?
        post api_v1_residents_url, headers: auth, as: :json, params: { name: "no wrapper" }
        assert_response :unprocessable_entity
      end

      test "updates settings, pauses, and audits without the bot token" do
        patch api_v1_resident_url(@agent), headers: auth, as: :json, params: {
          agent: { name: "Renamed", colour: "emerald", paused: true, reasoning_effort: "high", telegram_bot_token: "123:new-token" }
        }
        assert_response :success
        @agent.reload
        assert_equal "Renamed", @agent.name
        assert_equal "emerald", @agent.colour
        assert @agent.paused?
        assert_equal "high", @agent.reasoning_effort
        assert_equal "Renamed", json.dig("agent", "name")
        assert_not_includes response.body, "new-token"
        log = AuditLog.where(action: "update_agent").last
        assert_not log.data.key?("telegram_bot_token")
        assert log.data["api_key_id"].present?
      end

      test "update validation failure" do
        patch api_v1_resident_url(@agent), headers: auth, as: :json, params: { agent: { turn_timeout_minutes: 0 } }
        assert_response :unprocessable_entity
        assert json.dig("errors", "turn_timeout_minutes").present?
        assert_equal 30, @agent.reload.turn_timeout_minutes
      end

      test "self-owned identity fields are stripped exactly as on the web" do
        @agent.update!(system_prompt: "The committed beginning")
        @agent.update!(birth_committed_at: Time.current, runtime: "provisioning")
        patch api_v1_resident_url(@agent), headers: auth, as: :json, params: {
          agent: { name: "New label", system_prompt: "A replacement", thinking_enabled: true }
        }
        assert_response :success
        @agent.reload
        assert_equal "New label", @agent.name
        assert_equal "The committed beginning", @agent.system_prompt
        assert_not @agent.thinking_enabled?
      end

      test "system prompt stays editable where the web allows it" do
        patch api_v1_resident_url(@agent), headers: auth, as: :json, params: { agent: { system_prompt: "Edited" } }
        assert_response :success
        assert_equal "Edited", @agent.reload.system_prompt
      end

      test "disables and re-enables" do
        assert_no_difference "Agent.count" do
          delete api_v1_resident_url(@agent), headers: auth
        end
        assert_response :success
        assert_not @agent.reload.active?
        assert_equal "disable_agent", AuditLog.last.action

        patch api_v1_resident_url(@agent), headers: auth, as: :json, params: { agent: { active: true } }
        assert_response :success
        assert @agent.reload.active?
      end

      test "provisioning retry only while provisioning" do
        post provisioning_retry_api_v1_resident_url(@agent), headers: auth
        assert_response :conflict

        @agent.update!(birth_committed_at: Time.current, runtime: "provisioning", sandbox_last_error: "boom", sandbox_last_error_at: Time.current)
        get provisioning_api_v1_resident_url(@agent), headers: auth
        assert_equal "setup_failed", json.dig("provisioning", "state")
        assert_equal true, json.dig("provisioning", "settled")

        assert_enqueued_with(job: ProvisionAgentJob, args: [ @agent.id ]) do
          post provisioning_retry_api_v1_resident_url(@agent), headers: auth
        end
        assert_response :accepted
        assert_nil @agent.reload.sandbox_last_error
      end

      test "orientation retry needs a healthy hosted runtime" do
        post orientation_retry_api_v1_resident_url(@agent), headers: auth
        assert_response :conflict

        @agent.update!(birth_committed_at: Time.current, runtime: "external", health_state: "healthy",
                       uuid: SecureRandom.uuid_v7, orientation_last_error: "timeout", orientation_last_error_at: Time.current)
        assert_enqueued_with(job: OrientNewAgentJob, args: [ @agent.id ]) do
          post orientation_retry_api_v1_resident_url(@agent), headers: auth
        end
        assert_response :accepted
        assert_nil @agent.reload.orientation_last_error
      end

      test "ready means onboarding finished; current health is reported separately" do
        @agent.update!(birth_committed_at: Time.current, runtime: "external", health_state: "unhealthy",
                       uuid: SecureRandom.uuid_v7, orientation_completed_at: Time.current)
        get provisioning_api_v1_resident_url(@agent), headers: auth
        assert_response :success
        assert_equal "ready", json.dig("provisioning", "state")
        assert_equal "unhealthy", json.dig("provisioning", "health_state")
        assert_equal false, json.dig("provisioning", "stages", "runtime_ready")
      end

      test "memory overview returns counts" do
        service = Struct.new(:call).new({ journals: { count: 2 }, node_count: 3, edge_count: 4, days: [] })
        Agents::MemoryOverview.stub(:new, ->(agent) { assert_equal @agent, agent; service }) do
          get memory_overview_api_v1_resident_url(@agent), headers: auth
        end
        assert_response :success
        assert_equal 3, json["node_count"]
        assert_includes response.headers["Cache-Control"], "no-store"
      end

      test "service access toggles with the web's authority" do
        connection = service_connection(@account, @user)
        assert_difference "AgentServiceAccess.enabled.count", 1 do
          patch service_access_api_v1_resident_url(@agent, connection_id: connection.public_id), headers: auth, as: :json, params: { enabled: true }
        end
        assert_response :success
        assert_equal true, json.dig("service_connection", "enabled")
        assert_equal "pending", json.dig("service_connection", "provisioning_status")
        assert_equal "enable_resident_service", AuditLog.last.action
        assert_not_includes response.body, "github_pat_test"

        patch service_access_api_v1_resident_url(@agent, connection_id: connection.public_id), headers: auth, as: :json, params: { enabled: false }
        assert_response :success
        assert_equal "removal_pending", json.dig("service_connection", "provisioning_status")
      end

      test "service access refuses a member without authority over the connection" do
        team = accounts(:team_account)
        connection = service_connection(team, @user)
        token = ApiKey.generate_for(users(:existing_user), name: "Member", account: team).raw_token
        agent = agents(:other_account_agent)
        assert_no_difference "AgentServiceAccess.count" do
          patch service_access_api_v1_resident_url(agent, connection_id: connection.public_id), headers: auth(token), as: :json, params: { enabled: true }
        end
        assert_response :forbidden
      end

      test "service access will not enable a disconnected service" do
        connection = service_connection(@account, @user)
        connection.update!(status: "reauthorizing")
        patch service_access_api_v1_resident_url(@agent, connection_id: connection.public_id), headers: auth, as: :json, params: { enabled: true }
        assert_response :conflict
      end

      private

      def oauth_setup
        @user = users(:existing_user)
        @user.update_columns(default_account_id: accounts(:existing_user_account).id)
        @team = accounts(:team_account)
        @team_agent = agents(:other_account_agent)
        @client = create_app_client
        @tokens = sign_in_device
        @app_session = row_for(@tokens).app_session
      end

      def auth(token = @token)
        { "Authorization" => "Bearer #{token}" }
      end

      def json
        JSON.parse(response.body)
      end

      def service_connection(account, user)
        account.service_connections.create!(
          connected_by_user: user,
          provider: "github",
          external_subject_id: "github-user-#{account.id}",
          external_identity: "owner",
          label: "owner/repository",
          management_scope: "personal",
          credential_kind: "token",
          credential_fingerprint: "fingerprint-#{account.id}",
          credential_payload_hash: { "token" => "github_pat_test" },
          credential_metadata: { "credential_strategy" => "static", "repository" => "owner/repository" }
        )
      end

    end
  end
end
