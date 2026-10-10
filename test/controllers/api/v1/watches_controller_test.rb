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

      test "residents cannot connect repositories" do
        post api_v1_repositories_url, params: { full_name: "swombat/third" }, headers: resident_headers(@user, @resident), as: :json
        assert_includes [ 401, 403 ], response.status
        assert_equal 1, WatchedRepository.count
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
