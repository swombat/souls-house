require "test_helper"

class CommitStatusTest < ActiveSupport::TestCase

  REPO = "swombat/souls-house"
  DEPLOYED = "d" * 40
  MASTER = "e" * 40
  OLD = "1a2b3c4" + "0" * 33
  NEW = "5f6e7d8" + "0" * 33
  BRANCH = "9c8b7a6" + "0" * 33

  setup do
    @calls = []
    @responses = {}
    calls = @calls
    responses = @responses
    @original_fetcher = CommitStatus.fetcher
    CommitStatus.fetcher = ->(path) { calls << path; responses.fetch(path) { raise "unexpected #{path}" } }
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    CommitStatus.fetcher = @original_fetcher
    Rails.cache = @original_cache
  end

  def summary(deployed: DEPLOYED, master: MASTER, dirty: false)
    {
      repo: REPO,
      deployed: deployed && { sha: deployed, dirty: dirty },
      master: master && { sha: master }
    }
  end

  def compare(sha, target, status, base: nil)
    @responses["/repos/#{REPO}/compare/#{sha}...#{target}"] = [ 200, { "status" => status, "base_commit" => { "sha" => base || sha } } ]
  end

  def missing(sha, target, code = 404)
    @responses["/repos/#{REPO}/compare/#{sha}...#{target}"] = [ code, nil ]
  end

  test "deployed, merged and unmerged come from ancestry against the running revision then master" do
    compare("1a2b3c4", DEPLOYED, "ahead", base: OLD)
    compare("5f6e7d8", DEPLOYED, "behind", base: NEW)
    compare("5f6e7d8", MASTER, "ahead", base: NEW)
    compare("9c8b7a6", DEPLOYED, "diverged", base: BRANCH)
    compare("9c8b7a6", MASTER, "diverged", base: BRANCH)

    statuses = CommitStatus.lookup(%w[1a2b3c4 5f6e7d8 9c8b7a6], summary: summary)

    assert_equal({ "1a2b3c4" => "deployed", "5f6e7d8" => "merged", "9c8b7a6" => "unmerged" }, statuses)
  end

  test "the running revision itself needs no lookup; master needs only the live check" do
    compare(MASTER, DEPLOYED, "behind")

    statuses = CommitStatus.lookup([ DEPLOYED.first(7), MASTER ], summary: summary)

    assert_equal({ "ddddddd" => "deployed", MASTER => "merged" }, statuses)
    assert_equal [ "/repos/#{REPO}/compare/#{MASTER}...#{DEPLOYED}" ], @calls
  end

  test "not found and ambiguous stay unknown, never unmerged" do
    missing("abcdef1", DEPLOYED)
    missing("abc1234", DEPLOYED, 422)

    statuses = CommitStatus.lookup(%w[abcdef1 abc1234], summary: summary)

    assert_equal({ "abcdef1" => nil, "abc1234" => nil }, statuses)
  end

  test "a failed live check stays unknown rather than falling through to merged" do
    @responses["/repos/#{REPO}/compare/5f6e7d8...#{DEPLOYED}"] = [ 403, nil ]
    compare("5f6e7d8", MASTER, "ahead", base: NEW)

    assert_nil CommitStatus.lookup(%w[5f6e7d8], summary: summary)["5f6e7d8"]
  end

  test "network errors are unknown and not cached" do
    CommitStatus.fetcher = ->(_path) { raise Timeout::Error }
    assert_nil CommitStatus.lookup(%w[5f6e7d8], summary: summary)["5f6e7d8"]

    compare("5f6e7d8", DEPLOYED, "ahead", base: NEW)
    calls = @calls
    responses = @responses
    CommitStatus.fetcher = ->(path) { calls << path; responses.fetch(path) }
    assert_equal "deployed", CommitStatus.lookup(%w[5f6e7d8], summary: summary)["5f6e7d8"]
  end

  test "a compare that resolved some other commit is unknown" do
    compare("5f6e7d8", DEPLOYED, "ahead", base: BRANCH)

    assert_nil CommitStatus.lookup(%w[5f6e7d8], summary: summary)["5f6e7d8"]
  end

  test "facts are cached per running revision, so a rollback changes the answer" do
    compare("5f6e7d8", DEPLOYED, "ahead", base: NEW)
    assert_equal "deployed", CommitStatus.lookup(%w[5f6e7d8], summary: summary)["5f6e7d8"]
    assert_equal "deployed", CommitStatus.lookup(%w[5f6e7d8], summary: summary)["5f6e7d8"]
    assert_equal 1, @calls.size

    rolled_back = "c" * 40
    compare("5f6e7d8", rolled_back, "behind", base: NEW)
    compare("5f6e7d8", MASTER, "ahead", base: NEW)
    assert_equal "merged", CommitStatus.lookup(%w[5f6e7d8], summary: summary(deployed: rolled_back))["5f6e7d8"]
  end

  test "without a clean running revision there is no rocket, but master status still shows" do
    compare("5f6e7d8", MASTER, "ahead", base: NEW)

    assert_equal "merged", CommitStatus.lookup(%w[5f6e7d8], summary: summary(dirty: true))["5f6e7d8"]
    assert_equal "merged", CommitStatus.lookup(%w[5f6e7d8], summary: summary(deployed: nil))["5f6e7d8"]
  end

  test "without master or a running revision everything is unknown" do
    assert_equal({ "5f6e7d8" => nil }, CommitStatus.lookup(%w[5f6e7d8], summary: summary(deployed: nil, master: nil)))
    assert_empty @calls
  end

  test "only hex candidates are looked up, and uncached lookups are capped per request" do
    assert_equal({}, CommitStatus.lookup([ "zzzzzzz", "abc", "../../x", "1a2b3c4/../" ], summary: summary))

    shas = (1..30).map { |i| format("%07x", 0xa000000 + i) }
    shas.each { |sha| compare(sha, DEPLOYED, "ahead", base: sha + "0" * 33) }
    statuses = CommitStatus.lookup(shas, summary: summary)

    assert_equal CommitStatus::MAX_LOOKUPS, statuses.values.count("deployed")
    assert_equal CommitStatus::MAX_LOOKUPS, @calls.size
  end

end
