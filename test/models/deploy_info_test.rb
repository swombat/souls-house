require "test_helper"

class DeployInfoTest < ActiveSupport::TestCase

  MASTER = "b" * 40
  DEPLOYED = "a" * 40

  setup do
    @calls = []
    @responses = {}
    calls = @calls
    responses = @responses
    @original_fetcher = DeployInfo.fetcher
    DeployInfo.fetcher = ->(path) { calls << path; responses.fetch(path) { raise "unexpected #{path}" } }
    @responses["/repos/swombat/souls-house/commits/master"] = {
      "sha" => MASTER,
      "commit" => { "committer" => { "date" => "2026-10-04T14:24:30Z" }, "message" => "Merge pull request #150\n\nbody" }
    }
  end

  teardown do
    DeployInfo.fetcher = @original_fetcher
  end

  test "deployed revision comes from KAMAL_VERSION, master from GitHub, gap from compare" do
    @responses["/repos/swombat/souls-house/compare/#{DEPLOYED}...#{MASTER}"] = { "status" => "ahead", "ahead_by" => 3 }

    summary = DeployInfo.summary(version: DEPLOYED)

    assert_equal "aaaaaaa", summary[:deployed][:short]
    assert_not summary[:deployed][:dirty]
    assert_equal "bbbbbbb", summary[:master][:short]
    assert_equal "Merge pull request #150", summary[:master][:message]
    assert_equal "2026-10-04T14:24:30Z", summary[:master][:committed_at]
    assert_equal 3, summary[:behind_by]
  end

  test "deployed at master is up to date without a compare call" do
    summary = DeployInfo.summary(version: MASTER.first(12))

    assert_equal 0, summary[:behind_by]
    assert_equal [ "/repos/swombat/souls-house/commits/master" ], @calls
  end

  test "no revision means unknown, never live" do
    [ nil, "", "latest", "not-a-sha" ].each do |version|
      summary = DeployInfo.summary(version:)
      assert_nil summary[:deployed], version.inspect
      assert_nil summary[:behind_by], version.inspect
    end
  end

  test "uncommitted builds are flagged and get no gap" do
    summary = DeployInfo.summary(version: "#{DEPLOYED}_uncommitted_abcdef")

    assert summary[:deployed][:dirty]
    assert_equal DEPLOYED, summary[:deployed][:sha]
    assert_nil summary[:behind_by]
  end

  test "a build that is not on master gets no gap" do
    @responses["/repos/swombat/souls-house/compare/#{DEPLOYED}...#{MASTER}"] = { "status" => "diverged", "ahead_by" => 2, "behind_by" => 1 }

    assert_nil DeployInfo.summary(version: DEPLOYED)[:behind_by]
  end

  test "an ahead status without a positive count is unknown, never up to date" do
    [ nil, 0, -1, "3", 2.5 ].each do |count|
      Rails.cache.clear
      @responses["/repos/swombat/souls-house/compare/#{DEPLOYED}...#{MASTER}"] = { "status" => "ahead", "ahead_by" => count }
      assert_nil DeployInfo.summary(version: DEPLOYED)[:behind_by], count.inspect
    end
  end

  test "GitHub failure leaves master unknown and keeps the deployed line" do
    DeployInfo.fetcher = ->(_path) { raise Net::OpenTimeout }

    summary = DeployInfo.summary(version: DEPLOYED)

    assert_nil summary[:master]
    assert_nil summary[:behind_by]
    assert_equal DEPLOYED, summary[:deployed][:sha]
  end

end
