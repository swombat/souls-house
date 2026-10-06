require "test_helper"
require_relative "../support/github_import_fixtures"

class GithubResidentImportJobTest < ActiveSupport::TestCase

  include GithubImportFixtures

  test "approved import seeds provisions and retries without replacing the home" do
    request = import_request
    approve_fixture(request)
    calls = []
    volume = Object.new
    volume.define_singleton_method(:seed_from_directory!) { |root| calls << [ :seed, root ] }
    sandbox = Object.new
    sandbox.define_singleton_method(:spawn!) { calls << :spawn }
    sandbox.define_singleton_method(:recreate!) { calls << :recreate }
    sandbox.define_singleton_method(:active_turn?) { false }
    sandbox.define_singleton_method(:imported_runtime_trusted?) { true }
    Agents::GithubImportSource.stub(:new, source_stub(request)) do
      Agents::Volume.stub(:new, volume) do
        Agents::Sandbox.stub(:new, sandbox) { GithubResidentImportJob.perform_now(request.id) }
      end
    end
    request.reload
    assert_equal "ready", request.status
    assert_equal [ [ :seed, "/synthetic-home" ], :spawn ], calls
    assert request.agent.identity_seeded_at
    assert_nil request.agent.birth_committed_at
    assert_not request.agent.scheduled_wakes_enabled?
    assert_equal [ request.service_connection_id ], request.agent.agent_service_accesses.pluck(:service_connection_id)
    calls.clear
    request.update!(status: "approved")
    Agents::GithubImportSource.stub(:new, source_stub(request)) do
      Agents::Volume.stub(:new, volume) do
        Agents::Sandbox.stub(:new, sandbox) { GithubResidentImportJob.perform_now(request.id) }
      end
    end
    assert_equal [ :recreate ], calls
  end

  test "changed credential refuses before fetch or Docker" do
    request = import_request
    approve_fixture(request)
    request.service_connection.update!(credential_fingerprint: "changed")
    Agents::GithubImportSource.stub(:new, ->(*) { flunk "must not fetch" }) do
      assert_raises(Agent::RuntimeAvailability::Unavailable) { GithubResidentImportJob.perform_now(request.id) }
    end
    assert_equal "failed", request.reload.status
    assert_nil request.agent
  end

  test "seed failures preserve record and never make resident available" do
    request = import_request
    approve_fixture(request)
    volume = Object.new
    volume.define_singleton_method(:seed_from_directory!) { |_| raise Agents::Volume::SeedError, "private token secret" }
    Agents::GithubImportSource.stub(:new, source_stub(request)) do
      Agents::Volume.stub(:new, volume) do
        assert_raises(Agents::Volume::SeedError) { GithubResidentImportJob.perform_now(request.id) }
      end
    end
    assert_equal "failed", request.reload.status
    assert request.agent
    assert_not request.agent.active?
    assert_nil request.agent.identity_seeded_at
    assert_not_includes request.last_error, "private token"
  end

  test "untrusted runtime stays seeded inactive and permits explicit operator activation retry" do
    request = import_request
    approve_fixture(request)
    calls = []
    volume = Object.new
    volume.define_singleton_method(:seed_from_directory!) { |_| calls << :seed }
    sandbox = Object.new
    sandbox.define_singleton_method(:imported_runtime_trusted?) { false }
    sandbox.define_singleton_method(:spawn!) { flunk "must not start code before operator trust" }
    Agents::GithubImportSource.stub(:new, source_stub(request)) do
      Agents::Volume.stub(:new, volume) do
        Agents::Sandbox.stub(:new, sandbox) { GithubResidentImportJob.perform_now(request.id) }
      end
    end
    assert_equal [ :seed ], calls
    assert_equal "needs_runtime_trust", request.reload.status
    assert request.agent.identity_seeded_at
    assert_not request.agent.active?
    assert request.agent.paused?
    assert_enqueued_with(job: GithubResidentImportJob, args: [ request.id ]) { request.retry_activation!(users(:site_admin_user)) }
    assert_equal "approved", request.status
    sandbox.define_singleton_method(:imported_runtime_trusted?) { true }
    sandbox.define_singleton_method(:spawn!) { calls << :spawn }
    Agents::GithubImportSource.stub(:new, source_stub(request)) do
      Agents::Volume.stub(:new, volume) do
        Agents::Sandbox.stub(:new, sandbox) { GithubResidentImportJob.perform_now(request.id) }
      end
    end
    assert_equal [ :seed, :spawn ], calls
    assert_equal "ready", request.reload.status
  end

end
