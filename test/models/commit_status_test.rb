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

  def resolves(short, full)
    @responses["/repos/#{REPO}/commits/#{short}"] = [ 200, { "sha" => full } ]
  end

  def unresolved(short, code)
    @responses["/repos/#{REPO}/commits/#{short}"] = [ code, nil ]
  end

  def compare(full, target, status, base: full)
    @responses["/repos/#{REPO}/compare/#{full}...#{target}"] = [ 200, { "status" => status, "base_commit" => { "sha" => base } } ]
  end

  test "deployed, merged and unmerged come from ancestry of the resolved sha against the running revision then master" do
    resolves("1a2b3c4", OLD)
    resolves("5f6e7d8", NEW)
    resolves("9c8b7a6", BRANCH)
    compare(OLD, DEPLOYED, "ahead")
    compare(NEW, DEPLOYED, "behind")
    compare(NEW, MASTER, "ahead")
    compare(BRANCH, DEPLOYED, "diverged")
    compare(BRANCH, MASTER, "diverged")

    statuses = CommitStatus.lookup(%w[1a2b3c4 5f6e7d8 9c8b7a6], summary: summary)

    assert_equal({ "1a2b3c4" => "deployed", "5f6e7d8" => "merged", "9c8b7a6" => "unmerged" }, statuses)
  end

  test "an abbreviation of the running revision is still resolved by GitHub, not by prefix" do
    resolves("ddddddd", DEPLOYED)

    assert_equal "deployed", CommitStatus.lookup(%w[ddddddd], summary: summary)["ddddddd"]
    assert_equal [ "/repos/#{REPO}/commits/ddddddd" ], @calls
  end

  test "an ambiguous prefix of the running revision gets no badge" do
    unresolved("ddddddd", 422)

    assert_nil CommitStatus.lookup(%w[ddddddd], summary: summary)["ddddddd"]
    assert_equal [ "/repos/#{REPO}/commits/ddddddd" ], @calls
  end

  test "a resolution to a commit the abbreviation does not prefix is unknown" do
    resolves("5f6e7d8", BRANCH)

    assert_nil CommitStatus.lookup(%w[5f6e7d8], summary: summary)["5f6e7d8"]
  end

  test "a full sha equal to the running revision needs no lookup" do
    assert_equal({ DEPLOYED => "deployed" }, CommitStatus.lookup([ DEPLOYED ], summary: summary))
    assert_empty @calls
  end

  test "ancestry facts are keyed by full shas; resolutions expire, so a prefix that later turns ambiguous loses its badge" do
    resolves("5f6e7d8", NEW)
    compare(NEW, DEPLOYED, "ahead")
    assert_equal "deployed", CommitStatus.lookup(%w[5f6e7d8], summary: summary)["5f6e7d8"]

    unresolved("5f6e7d8", 422)
    travel CommitStatus::RESOLUTION_TTL + 1.minute do
      assert_nil CommitStatus.lookup(%w[5f6e7d8], summary: summary)["5f6e7d8"]
    end

    # The full sha's fact survives, and needs no new compare.
    calls_before = @calls.size
    travel CommitStatus::RESOLUTION_TTL + 1.minute do
      assert_equal "deployed", CommitStatus.lookup([ NEW ], summary: summary)[NEW]
    end
    assert_equal calls_before, @calls.size
  end

  test "not found and ambiguous stay unknown, never unmerged" do
    unresolved("abcdef1", 404)
    unresolved("abc1234", 422)

    statuses = CommitStatus.lookup(%w[abcdef1 abc1234], summary: summary)

    assert_equal({ "abcdef1" => nil, "abc1234" => nil }, statuses)
  end

  test "a failed live check stays unknown rather than falling through to merged" do
    resolves("5f6e7d8", NEW)
    @responses["/repos/#{REPO}/compare/#{NEW}...#{DEPLOYED}"] = [ 403, nil ]
    compare(NEW, MASTER, "ahead")

    assert_nil CommitStatus.lookup(%w[5f6e7d8], summary: summary)["5f6e7d8"]
  end

  test "network errors are unknown and not cached" do
    CommitStatus.fetcher = ->(_path) { raise Timeout::Error }
    assert_nil CommitStatus.lookup(%w[5f6e7d8], summary: summary)["5f6e7d8"]

    resolves("5f6e7d8", NEW)
    compare(NEW, DEPLOYED, "ahead")
    calls = @calls
    responses = @responses
    CommitStatus.fetcher = ->(path) { calls << path; responses.fetch(path) }
    assert_equal "deployed", CommitStatus.lookup(%w[5f6e7d8], summary: summary)["5f6e7d8"]
  end

  test "a compare that answered about some other commit is unknown" do
    compare(NEW, DEPLOYED, "ahead", base: BRANCH)

    assert_nil CommitStatus.lookup([ NEW ], summary: summary)[NEW]
  end

  test "facts are cached per running revision, so a rollback changes the answer" do
    compare(NEW, DEPLOYED, "ahead")
    assert_equal "deployed", CommitStatus.lookup([ NEW ], summary: summary)[NEW]
    assert_equal "deployed", CommitStatus.lookup([ NEW ], summary: summary)[NEW]
    assert_equal 1, @calls.size

    rolled_back = "c" * 40
    compare(NEW, rolled_back, "behind")
    compare(NEW, MASTER, "ahead")
    assert_equal "merged", CommitStatus.lookup([ NEW ], summary: summary(deployed: rolled_back))[NEW]
  end

  test "a missing, short or dirty running revision is unknown, never 'not yet deployed'" do
    resolves("5f6e7d8", NEW)
    compare(NEW, MASTER, "ahead")

    [ summary(deployed: nil), summary(deployed: "ddddddd"), summary(dirty: true) ].each do |s|
      assert_equal({ "5f6e7d8" => nil }, CommitStatus.lookup(%w[5f6e7d8], summary: s))
    end
    assert_empty @calls
  end

  test "without master everything is unknown" do
    assert_equal({ "5f6e7d8" => nil }, CommitStatus.lookup(%w[5f6e7d8], summary: summary(master: nil)))
    assert_empty @calls
  end

  test "revision names the pair every answer was measured against" do
    assert_equal "#{DEPLOYED}:#{MASTER}", CommitStatus.revision(summary)
    assert_equal ":#{MASTER}", CommitStatus.revision(summary(deployed: nil))
  end

  test "only hex candidates are looked up, and uncached lookups are capped per request" do
    assert_equal({}, CommitStatus.lookup([ "zzzzzzz", "abc", "../../x", "1a2b3c4/../" ], summary: summary))

    shas = (1..30).map { |i| format("%040x", 0xa000000 + i) }
    shas.each { |sha| compare(sha, DEPLOYED, "ahead") }
    statuses = CommitStatus.lookup(shas, summary: summary)

    assert_equal CommitStatus::MAX_LOOKUPS, statuses.values.count("deployed")
    assert_equal CommitStatus::MAX_LOOKUPS, @calls.size
  end

end
