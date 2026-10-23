require "test_helper"
require "webmock/minitest"

class CommitBadgesTest < ActiveSupport::TestCase

  HOUSE = "swombat/souls-house"
  WEB = "acme/web"
  API = "acme/api"
  DEPLOYED = "d" * 40
  MASTER = "e" * 40
  WEB_MAIN = "a" * 40
  API_MAIN = "b" * 40
  COMMIT = "51625a7" + "0" * 33
  SHORT = "51625a7"

  setup do
    @responses = {}
    @tokens = []
    responses = @responses
    tokens = @tokens
    @original_fetcher = CommitStatus.fetcher
    @original_deploy_fetcher = DeployInfo.fetcher
    CommitStatus.fetcher = ->(path, token: nil) { tokens << [ path, token ]; responses.fetch(path) { [ 404, nil ] } }
    DeployInfo.fetcher = ->(path) { path == "/repos/#{HOUSE}/commits/master" ? { "sha" => MASTER } : nil }
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @original_version = ENV["KAMAL_VERSION"]
    ENV["KAMAL_VERSION"] = DEPLOYED

    @owner = users(:user_1)
    @account = accounts(:team_account)
    @connection = github_connection
  end

  teardown do
    CommitStatus.fetcher = @original_fetcher
    DeployInfo.fetcher = @original_deploy_fetcher
    Rails.cache = @original_cache
    ENV["KAMAL_VERSION"] = @original_version
  end

  test "config lists the account's badge repositories, and the house repository only for site admins" do
    repository(WEB, commit_badges: true)
    repository(API, commit_badges: false)

    assert_equal({ house_repo: nil, repos: [ WEB ] }, CommitBadges.config_for(@account, @owner))
    assert_equal({ house_repo: HOUSE, repos: [ WEB ] }, CommitBadges.config_for(@account, users(:site_admin_user)))
  end

  test "an account repository is on or off its default branch, read with the connection's token, never deployed" do
    repository(WEB, commit_badges: true)
    default_branch(WEB, "main", WEB_MAIN)
    commit(WEB, SHORT, COMMIT)
    compare(WEB, COMMIT, WEB_MAIN, "ahead")

    result = CommitBadges.new(account: @account, user: @owner).lookup([ SHORT, "#{WEB}@#{SHORT}" ])

    assert_equal({ SHORT => "on_default", "#{WEB}@#{SHORT}" => "on_default" }, result[:statuses])
    assert_equal "#{WEB}=#{WEB_MAIN}", result[:revision]
    assert @tokens.all? { |_, token| token == "github_pat_test" }
    assert @tokens.none? { |path, _| path.include?(DEPLOYED) }
  end

  test "a bare sha only one of several repositories has takes that repository's status" do
    repository(WEB, commit_badges: true)
    repository(API, commit_badges: true)
    default_branch(WEB, "main", WEB_MAIN)
    default_branch(API, "trunk", API_MAIN)
    commit(WEB, SHORT, COMMIT)
    compare(WEB, COMMIT, WEB_MAIN, "diverged")
    @responses["/repos/#{WEB}/commits/#{COMMIT}/pulls"] = [ 200, [] ]
    absent(API, SHORT)

    assert_equal({ SHORT => "off_default" }, CommitBadges.new(account: @account, user: @owner).lookup([ SHORT ])[:statuses])
  end

  test "a bare sha two repositories both have, or one could not answer for, gets no badge" do
    repository(WEB, commit_badges: true)
    repository(API, commit_badges: true)
    default_branch(WEB, "main", WEB_MAIN)
    default_branch(API, "trunk", API_MAIN)
    commit(WEB, SHORT, COMMIT)
    compare(WEB, COMMIT, WEB_MAIN, "ahead")
    commit(API, SHORT, COMMIT)
    compare(API, COMMIT, API_MAIN, "ahead")

    assert_equal({ SHORT => nil }, CommitBadges.new(account: @account, user: @owner).lookup([ SHORT ])[:statuses])

    Rails.cache.clear
    @responses["/repos/#{API}/commits/#{SHORT}"] = [ 500, nil ]
    assert_equal({ SHORT => nil }, CommitBadges.new(account: @account, user: @owner).lookup([ SHORT ])[:statuses])
  end

  test "an ambiguous prefix, or a repository the token can no longer read, is not proof a bare sha is elsewhere" do
    repository(WEB, commit_badges: true)
    repository(API, commit_badges: true)
    default_branch(WEB, "main", WEB_MAIN)
    default_branch(API, "trunk", API_MAIN)
    commit(WEB, SHORT, COMMIT)
    compare(WEB, COMMIT, WEB_MAIN, "ahead")

    # GitHub's answer for a prefix that names several commits.
    @responses["/repos/#{API}/commits/#{SHORT}"] = [ 422, { "message" => "The SHA #{SHORT} is ambiguous" } ]
    assert_equal({ SHORT => nil }, CommitBadges.new(account: @account, user: @owner).lookup([ SHORT ])[:statuses])
    assert_equal({ SHORT => nil }, CommitBadges.new(account: @account, user: @owner).lookup([ SHORT ])[:statuses], "an ambiguous answer is not cached as missing")

    # Access to a private repository lost while the connection still says connected.
    Rails.cache.clear
    @responses.delete("/repos/#{API}")
    @responses.delete("/repos/#{API}/commits/trunk")
    @responses["/repos/#{API}/commits/#{SHORT}"] = [ 404, { "message" => "Not Found" } ]
    assert_equal "connected", @connection.reload.status
    assert_equal({ SHORT => nil }, CommitBadges.new(account: @account, user: @owner).lookup([ SHORT ])[:statuses])

    # Only "No commit found" from a readable repository rules it out.
    Rails.cache.clear
    default_branch(API, "trunk", API_MAIN)
    absent(API, SHORT)
    assert_equal({ SHORT => "on_default" }, CommitBadges.new(account: @account, user: @owner).lookup([ SHORT ])[:statuses])
  end

  test "through the real GitHub adapter, a readable repository's \"No commit found\" lets another repository's bare sha be badged" do
    CommitStatus.fetcher = @original_fetcher
    repository(WEB, commit_badges: true)
    repository(API, commit_badges: true)
    api = "https://api.github.com/repos"
    json = ->(status, body) { { status:, body: body.to_json, headers: { "Content-Type" => "application/json" } } }
    stub_request(:get, "#{api}/#{WEB}").to_return(json.(200, default_branch: "main"))
    stub_request(:get, "#{api}/#{WEB}/commits/main").to_return(json.(200, sha: WEB_MAIN))
    stub_request(:get, "#{api}/#{WEB}/commits/#{SHORT}").to_return(json.(200, sha: COMMIT))
    stub_request(:get, "#{api}/#{WEB}/compare/#{COMMIT}...#{WEB_MAIN}").to_return(json.(200, status: "ahead", base_commit: { sha: COMMIT }))
    stub_request(:get, "#{api}/#{API}").to_return(json.(200, default_branch: "trunk"))
    stub_request(:get, "#{api}/#{API}/commits/trunk").to_return(json.(200, sha: API_MAIN))
    stub_request(:get, "#{api}/#{API}/commits/#{SHORT}").to_return(json.(422, message: "No commit found for SHA: #{SHORT}"))

    assert_equal({ SHORT => "on_default" }, CommitBadges.new(account: @account, user: @owner).lookup([ SHORT ])[:statuses])

    Rails.cache.clear
    stub_request(:get, "#{api}/#{API}/commits/#{SHORT}").to_return(json.(422, message: "The SHA #{SHORT} is ambiguous"))
    assert_equal({ SHORT => nil }, CommitBadges.new(account: @account, user: @owner).lookup([ SHORT ])[:statuses])
  end

  test "a URL naming a repository is only asked of that repository, and an unknown one gets nothing" do
    repository(WEB, commit_badges: true)
    default_branch(WEB, "main", WEB_MAIN)
    commit(WEB, SHORT, COMMIT)
    compare(WEB, COMMIT, WEB_MAIN, "ahead")

    statuses = CommitBadges.new(account: @account, user: @owner).lookup([ "acme/WEB@#{SHORT}", "other/repo@#{SHORT}" ])[:statuses]

    assert_equal({ "#{WEB}@#{SHORT}" => "on_default", "other/repo@#{SHORT}" => nil }, statuses)
  end

  test "site admins keep deployed for the house repository alongside the account's" do
    repository(WEB, commit_badges: true)
    default_branch(WEB, "main", WEB_MAIN)
    absent(WEB, SHORT)
    commit(HOUSE, SHORT, COMMIT)
    compare(HOUSE, COMMIT, DEPLOYED, "ahead")

    statuses = CommitBadges.new(account: @account, user: users(:site_admin_user)).lookup([ SHORT, "#{HOUSE}@#{SHORT}" ])[:statuses]

    assert_equal({ SHORT => "deployed", "#{HOUSE}@#{SHORT}" => "deployed" }, statuses)
  end

  test "repositories that are removed, switched off or on a disconnected connection are not sources" do
    repository(WEB, commit_badges: true).update!(removed_at: Time.current)
    repository(API, commit_badges: true)
    @connection.update!(status: "revoked")

    assert_equal [], CommitBadges.config_for(@account, @owner)[:repos]
  end

  test "answers about an account's repository are not shared with another account" do
    repository(WEB, commit_badges: true)
    default_branch(WEB, "main", WEB_MAIN)
    commit(WEB, SHORT, COMMIT)
    compare(WEB, COMMIT, WEB_MAIN, "ahead")
    CommitBadges.new(account: @account, user: @owner).lookup([ SHORT ])

    other = accounts(:personal_account)
    @account, @connection = other, github_connection(other, subject: "other-github")
    repository(WEB, commit_badges: true)
    @responses.clear

    assert_equal({ SHORT => nil }, CommitBadges.new(account: other, user: @owner).lookup([ SHORT ])[:statuses])
  end

  private

  def github_connection(account = @account, subject: "github-badges")
    account.service_connections.create!(
      connected_by_user: @owner, provider: "github", external_subject_id: subject, external_identity: "acme",
      label: "acme", management_scope: "personal", status: "connected", credential_kind: "token",
      credential_fingerprint: "#{subject}-fingerprint", credential_payload_hash: { "token" => "github_pat_test" },
      credential_metadata: { "credential_strategy" => "static" }
    )
  end

  def repository(full_name, **attributes)
    owner, name = full_name.split("/")
    WatchedRepository.create!(
      account: @account, service_connection: @connection, created_by_user: @owner,
      owner:, name:, full_name:, hook_status: "installed", **attributes
    )
  end

  def default_branch(repo, branch, head)
    @responses["/repos/#{repo}"] = [ 200, { "default_branch" => branch } ]
    @responses["/repos/#{repo}/commits/#{branch}"] = [ 200, { "sha" => head } ]
  end

  def commit(repo, ref, full)
    @responses["/repos/#{repo}/commits/#{ref}"] = [ 200, { "sha" => full } ]
    @responses["/repos/#{repo}/commits/#{full}"] = [ 200, { "sha" => full } ]
  end

  # What GitHub says when it can read the repository and it has no such commit.
  def absent(repo, ref)
    @responses["/repos/#{repo}/commits/#{ref}"] = [ 422, { "message" => "No commit found for SHA: #{ref}" } ]
  end

  def compare(repo, full, target, status)
    @responses["/repos/#{repo}/compare/#{full}...#{target}"] = [ 200, { "status" => status, "base_commit" => { "sha" => full } } ]
  end

end
