# Builders for repository-watch tests: a GitHub connection, a connected
# repository, a resident with a grant and a room, and a fake GitHub client
# that answers from canned data (or raises) instead of calling the API.
module RepositoryWatchHelpers

  PUBLIC_URL = "https://house.example.test".freeze

  # The receiver URL needs the house's public URL, which the test
  # environment leaves blank.
  def self.included(base)
    base.setup do
      @previous_public_url = Rails.configuration.x.public_url
      Rails.configuration.x.public_url = PUBLIC_URL
    end
    base.teardown { Rails.configuration.x.public_url = @previous_public_url }
  end

  SHA = "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0".freeze
  OTHER_SHA = "0f0e0d0c0b0a09080706050403020100ffeeddcc".freeze

  class FakeGithub

    attr_accessor :runs, :deployments, :statuses, :error, :commit, :calls

    def initialize(runs: [], deployments: [], statuses: {}, error: nil, commit: nil)
      @runs = runs
      @deployments = deployments
      @statuses = statuses
      @error = error
      @commit = commit
      @calls = []
    end

    def workflow_runs(full_name, head_sha:)
      record(:workflow_runs, full_name, head_sha)
      runs
    end

    def deployments(full_name, sha: nil, environment: nil, since: nil)
      record(:deployments, full_name, sha, environment, since)
      since ? @deployments.take_while { |deployment| Time.iso8601(deployment["created_at"]) >= since } : @deployments
    end

    def deployment_statuses(full_name, deployment_id)
      record(:deployment_statuses, full_name, deployment_id)
      statuses.fetch(deployment_id, [])
    end

    def commit_sha(full_name, ref)
      record(:commit_sha, full_name, ref)
      commit
    end

    def repository(full_name)
      record(:repository, full_name)
      { "id" => 99, "full_name" => full_name, "private" => true }
    end

    def create_hook(full_name, url:, secret:)
      record(:create_hook, full_name, url)
      { "id" => 4242 }
    end

    def delete_hook(full_name, hook_id)
      record(:delete_hook, full_name, hook_id)
    end

    private

    def record(*call)
      calls << call
      raise error if error
    end

  end

  def with_fake_github(fake = FakeGithub.new, &block)
    RepositoryWatches::GithubClient.stub(:new, ->(*) { fake }, &block)
  end

  def build_watch_world(account: accounts(:personal_account), user: users(:user_1))
    @account = account
    @user = user
    @connection = account.service_connections.create!(
      connected_by_user: user,
      provider: "github",
      external_subject_id: "github-user-#{SecureRandom.hex(3)}",
      external_identity: "dad",
      management_scope: "personal",
      credential_kind: "token",
      credential_fingerprint: "fp-#{SecureRandom.hex(4)}",
      credential_payload_hash: { "token" => "github_pat_test" }
    )
    @repository = account.watched_repositories.create!(
      service_connection: @connection,
      created_by_user: user,
      provider: "github",
      owner: "swombat",
      name: "other-repo",
      full_name: "swombat/other-repo",
      hook_status: "installed",
      private_repository: true
    )
    @resident = account.agents.create!(name: "Watcher", system_prompt: "Test", runtime: "external")
    @resident.agent_service_accesses.create!(service_connection: @connection, enabled: true)
    @chat = account.chats.new(title: "CI room", manual_responses: true)
    @chat.agents = [ @resident ]
    @chat.save!
  end

  def arm_watch(by: @resident, event_kind: "workflow_run", filter: { "head_sha" => SHA, "workflow_name" => "CI" }, wake: true, chat: @chat, github: FakeGithub.new, **options)
    with_fake_github(github) do
      RepositoryWatch.arm!(repository: @repository, chat: chat, by: by, event_kind: event_kind, filter: filter, wake: wake, **options)
    end
  end

  def completed_run(sha: SHA, name: "CI", conclusion: "success", id: 777, attempt: 1)
    { "id" => id, "run_attempt" => attempt, "name" => name, "head_sha" => sha, "status" => "completed",
      "conclusion" => conclusion, "html_url" => "https://github.com/swombat/other-repo/actions/runs/#{id}",
      "updated_at" => "2026-10-10T12:00:00Z" }
  end

  def signed_headers(body, event:, guid: SecureRandom.uuid, secret: @repository.hook_secret)
    {
      "CONTENT_TYPE" => "application/json",
      "X-GitHub-Event" => event,
      "X-GitHub-Delivery" => guid,
      "X-Hub-Signature-256" => RepositoryWatches::Signature.sign(secret, body)
    }
  end

end
