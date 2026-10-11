require "test_helper"
require "support/repository_watch_helpers"
require "support/api_human_key_helpers"

module Api
  module V1
    class WatchesControllerTest < ActionDispatch::IntegrationTest

      include RepositoryWatchHelpers
      include ApiHumanKeyHelpers
      include ActiveJob::TestHelper

      setup { build_watch_world }

      def arm_params(**overrides)
        { repository: "swombat/other-repo", event: "workflow_run", workflow: "CI", sha: SHA, chat_id: @chat.to_param, wake: true }.merge(overrides)
      end

      test "a resident with a grant arms a watch for its room" do
        assert_enqueued_with(job: RepositoryWatchReconcileJob) do
          post api_v1_watches_url, params: arm_params, headers: resident_headers(@user, @resident), as: :json
        end
        assert_response :created
        watch = response.parsed_body["watch"]
        assert_equal [ "armed", "pending", true, "workflow_run" ], watch.values_at("state", "reconcile_status", "wake", "event")
        assert_equal({ "type" => "resident", "id" => @resident.to_param, "name" => "Watcher" }, watch["created_by"])
      end

      test "no grant is 403" do
        @resident.agent_service_accesses.update_all(enabled: false)
        post api_v1_watches_url, params: arm_params, headers: resident_headers(@user, @resident), as: :json
        assert_response :forbidden
      end

      test "a bad filter is 422 with the reason" do
        post api_v1_watches_url, params: arm_params(sha: "nothex"), headers: resident_headers(@user, @resident), as: :json
        assert_response :unprocessable_entity
        assert_match(/sha/, response.parsed_body["error"])
      end

      test "an unknown repository is 404" do
        post api_v1_watches_url, params: arm_params(repository: "swombat/nope"), headers: resident_headers(@user, @resident), as: :json
        assert_response :not_found
      end

      test "a person arms one without a wake, lists, and cancels" do
        headers = human_headers(@user, @account)
        post api_v1_watches_url, params: arm_params(wake: false), headers: headers, as: :json
        assert_response :created
        id = response.parsed_body.dig("watch", "id")

        get api_v1_watches_url, headers: headers
        assert_equal [ id ], response.parsed_body["watches"].map { |watch| watch["id"] }

        delete api_v1_watch_url(id), headers: headers
        assert_response :ok
        assert_equal "cancelled", response.parsed_body.dig("watch", "state")
      end

      test "a resident sees only the watches it armed" do
        arm_watch(by: @user, wake: false)
        mine = arm_watch
        get api_v1_watches_url, headers: resident_headers(@user, @resident)
        assert_equal [ mine.to_param ], response.parsed_body["watches"].map { |watch| watch["id"] }
      end

      test "a resident lists repositories only on connections it holds a grant for" do
        get api_v1_repositories_url, headers: resident_headers(@user, @resident)
        assert_equal [ "swombat/other-repo" ], response.parsed_body["repositories"].map { |repository| repository["full_name"] }
        refute response.parsed_body["repositories"].first.key?("setup"), "residents never see the hook secret"

        @resident.agent_service_accesses.update_all(enabled: false)
        get api_v1_repositories_url, headers: resident_headers(@user, @resident)
        assert_empty response.parsed_body["repositories"]
      end

      test "a resident with a grant connects a repository through that connection, recorded as its own" do
        github = FakeGithub.new
        with_fake_github(github) do
          post api_v1_repositories_url, params: { full_name: "swombat/third" }, headers: resident_headers(@user, @resident), as: :json
        end
        assert_response :created
        body = response.parsed_body["repository"]
        assert_equal [ "swombat/third", "installing", @connection.public_id ], body.values_at("full_name", "hook_status", "service_connection_id")
        assert_equal({ "type" => "resident", "id" => @resident.to_param, "name" => "Watcher" }, body["connected_by"])
        refute body.key?("setup"), "a resident never sees the hook secret"
        assert_includes github.calls.map(&:first), :create_hook, "the hook is installed with the granted connection's token"

        repository = WatchedRepository.find_by!(full_name: "swombat/third")
        assert_equal [ @resident.id, nil, @connection.id ], [ repository.created_by_agent_id, repository.created_by_user_id, repository.service_connection_id ]
        audit = AuditLog.find_by!(action: "repository_watch.connect", auditable: repository)
        assert_equal [ @resident.id, "resident" ], audit.data.values_at("agent_id", "actor")
      end

      test "a resident without a grant cannot connect a repository" do
        @resident.agent_service_accesses.update_all(enabled: false)
        with_fake_github do
          post api_v1_repositories_url, params: { full_name: "swombat/third" }, headers: resident_headers(@user, @resident), as: :json
        end
        assert_response :forbidden
        assert_equal 1, WatchedRepository.count
      end

      test "a resident cannot connect through a GitHub connection it holds no grant on" do
        other = @account.service_connections.create!(
          connected_by_user: @user, provider: "github", external_subject_id: "github-other", external_identity: "other",
          management_scope: "personal", credential_kind: "token", credential_fingerprint: "fp-other",
          credential_payload_hash: { "token" => "github_pat_other" }
        )
        with_fake_github do
          post api_v1_repositories_url, params: { full_name: "swombat/third", service_connection_id: other.public_id },
                                        headers: resident_headers(@user, @resident), as: :json
        end
        assert_response :not_found
        assert_equal 1, WatchedRepository.count
      end

      test "a grant on a connection that is no longer connected does not let a resident connect" do
        @connection.update_columns(status: "revoked")
        with_fake_github do
          post api_v1_repositories_url, params: { full_name: "swombat/third" }, headers: resident_headers(@user, @resident), as: :json
        end
        assert_response :forbidden
        assert_equal 1, WatchedRepository.count
      end

      test "when GitHub refuses the resident's connection the hook, it is left for manual setup without the secret" do
        github = FakeGithub.new
        def github.create_hook(*, **) = raise(RepositoryWatches::GithubClient::Error.new("Not Found", status: 404))
        with_fake_github(github) do
          post api_v1_repositories_url, params: { full_name: "swombat/third" }, headers: resident_headers(@user, @resident), as: :json
        end
        assert_response :created
        assert_equal "manual", response.parsed_body.dig("repository", "hook_status")
        refute response.parsed_body["repository"].key?("setup"), "the secret is for a person who can manage the connection"
      end

      test "a resident disconnects a repository it connected, but not one someone else connected" do
        with_fake_github do
          post api_v1_repositories_url, params: { full_name: "swombat/third" }, headers: resident_headers(@user, @resident), as: :json
        end
        mine = WatchedRepository.find(response.parsed_body.dig("repository", "id"))

        with_fake_github do
          delete api_v1_repository_url(@repository.to_param), headers: resident_headers(@user, @resident)
        end
        assert_response :forbidden
        refute @repository.reload.removed?

        with_fake_github do
          delete api_v1_repository_url(mine.to_param), headers: resident_headers(@user, @resident)
        end
        assert_response :no_content
        assert mine.reload.removed?
      end

      test "a person connects a repository; GitHub refusing the hook leaves it for manual setup" do
        github = FakeGithub.new
        def github.create_hook(*, **) = raise(RepositoryWatches::GithubClient::Error.new("Not Found", status: 404))
        with_fake_github(github) do
          post api_v1_repositories_url, params: { full_name: "swombat/third", service_connection_id: @connection.public_id },
                                        headers: human_headers(@user, @account), as: :json
        end
        assert_response :created
        repository = response.parsed_body["repository"]
        assert_equal [ "swombat/third", "manual" ], repository.values_at("full_name", "hook_status")
        assert repository.dig("setup", "secret").present?, "the person who must paste it into GitHub sees the secret"
      end

      test "a person who can manage the connection disconnects a repository, cancelling its watches" do
        watch = arm_watch(by: @user, wake: false)
        with_fake_github do
          delete api_v1_repository_url(@repository.to_param), headers: human_headers(@user, @account)
        end
        assert_response :no_content
        assert @repository.reload.removed?
        assert_equal "cancelled", watch.reload.state
      end

    end
  end
end
