require "test_helper"
require "webmock/minitest"

class AgentRepoCreatorTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @account.update!(github_pat: "ghp_test", github_login: "octocat")
  end

  test "validates github token and returns login" do
    request = stub_request(:get, "https://api.github.com/user")
      .with(headers: { "Authorization" => "Bearer ghp_test" })
      .to_return(status: 200, body: { login: "octocat" }.to_json)

    assert_equal "octocat", AgentRepoCreator.validate_token!("ghp_test")
    assert_requested request
  end

  test "creates a repo from the runtime template" do
    request = stub_request(:post, "https://api.github.com/repos/swombat/helix-kit-agents/generate")
      .with(body: hash_including(owner: "octocat", name: "research-agent", private: true))
      .to_return(status: 201, body: repo_response.to_json)

    repo = creator.create_repo!

    assert_equal "octocat", repo.owner
    assert_equal "research-agent", repo.name
    assert_equal "git@github.com:octocat/research-agent.git", repo.ssh_url
    assert_requested request
  end

  test "creates a read-write deploy key" do
    repo = repo_result
    request = stub_request(:post, "https://api.github.com/repos/octocat/research-agent/keys")
      .with(body: hash_including(key: "PUBLIC KEY", read_only: false))
      .to_return(status: 201, body: { id: 12345 }.to_json)

    deploy_key = creator.stub(:generate_deploy_key, [ "PRIVATE KEY", "PUBLIC KEY" ]) do
      creator.create_deploy_key!(repo)
    end

    assert_equal "12345", deploy_key.id
    assert_equal "PRIVATE KEY", deploy_key.private_key
    assert_requested request
  end

  test "commits identity, credentials, and deploy files" do
    repo = repo_result
    stub_request(:get, %r{\Ahttps://api\.github\.com/repos/octocat/research-agent/contents/})
      .to_return(status: 404, body: { message: "Not Found" }.to_json)
    requests = stub_request(:put, %r{\Ahttps://api\.github\.com/repos/octocat/research-agent/contents/})
      .to_return(status: 201, body: { content: { path: "file" } }.to_json)

    creator.commit_runtime_files!(
      repo,
      identity_files: {
        "soul.md" => "# Soul",
        "memory/.keep" => ""
      },
      credentials_yml_enc: "encrypted",
      deploy_yml: "agent_id: research"
    )

    assert_requested requests, times: 3
    assert_requested :put, "https://api.github.com/repos/octocat/research-agent/contents/identity/soul.md"
    assert_requested :put, "https://api.github.com/repos/octocat/research-agent/contents/credentials.yml.enc"
    assert_requested :put, "https://api.github.com/repos/octocat/research-agent/contents/deploy.yml"
  end

  test "updates existing runtime files by sending current sha" do
    repo = repo_result
    stub_request(:get, "https://api.github.com/repos/octocat/research-agent/contents/credentials.yml.enc")
      .to_return(status: 200, body: { sha: "existing-sha" }.to_json)
    put = stub_request(:put, "https://api.github.com/repos/octocat/research-agent/contents/credentials.yml.enc")
      .with(body: hash_including(sha: "existing-sha"))
      .to_return(status: 200, body: { content: { path: "credentials.yml.enc" } }.to_json)

    creator.send(:put_file, repo, "credentials.yml.enc", "encrypted", message: "Update credentials")

    assert_requested put
  end

  test "generated deploy yml uses runtime-compatible image tag and model key" do
    deploy = YAML.safe_load(creator.deploy_yml(repo_result))

    assert_equal "research-assistant", deploy.fetch("agent_id")
    assert_equal "https://research-assistant.helixagents.swombat.io", deploy.fetch("endpoint_url")
    assert_equal "anthropic", deploy.fetch("provider")
    assert_equal "claude-haiku-4-5", deploy.fetch("model")
    assert_equal "research-agent-latest", deploy.fetch("image_tag")
    assert_equal "helix-agents", deploy.fetch("vm_host")
    refute_match ":", deploy.fetch("image_tag"), "compose prefixes image_tag as a Docker tag, so it must not contain ':'"
  end

  test "generated deploy yml supports configurable runtime domain and vm host" do
    old_domain = ENV["SOULSHOUSE_AGENT_RUNTIME_DOMAIN"]
    old_vm_host = ENV["SOULSHOUSE_AGENT_RUNTIME_VM_HOST"]
    ENV["SOULSHOUSE_AGENT_RUNTIME_DOMAIN"] = "agents.example.test"
    ENV["SOULSHOUSE_AGENT_RUNTIME_VM_HOST"] = "agent-vm"

    deploy = YAML.safe_load(creator.deploy_yml(repo_result))

    assert_equal "https://research-assistant.agents.example.test", deploy.fetch("endpoint_url")
    assert_equal "agent-vm", deploy.fetch("vm_host")
  ensure
    ENV["SOULSHOUSE_AGENT_RUNTIME_DOMAIN"] = old_domain
    ENV["SOULSHOUSE_AGENT_RUNTIME_VM_HOST"] = old_vm_host
  end

  private

  def creator
    @creator ||= AgentRepoCreator.new(account: @account, agent: @agent, repo_name: "research-agent")
  end

  def repo_result
    AgentRepoCreator::Result.new(
      owner: "octocat",
      name: "research-agent",
      html_url: "https://github.com/octocat/research-agent",
      ssh_url: "git@github.com:octocat/research-agent.git",
      clone_url: "https://github.com/octocat/research-agent.git",
      default_branch: "main"
    )
  end

  def repo_response
    {
      owner: { login: "octocat" },
      name: "research-agent",
      html_url: "https://github.com/octocat/research-agent",
      ssh_url: "git@github.com:octocat/research-agent.git",
      clone_url: "https://github.com/octocat/research-agent.git",
      default_branch: "main"
    }
  end

end
