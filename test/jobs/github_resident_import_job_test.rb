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

  test "switch turned on during the checkout refuses before a home is made" do
    request = import_request
    approve_fixture(request)
    Setting.instance.update!(new_residents_on_vm: false)
    source = Object.new
    source.define_singleton_method(:with_checkout) do |branch:, commit_sha: nil, &block|
      Setting.instance.update!(new_residents_on_vm: true, vm_resident_limit: 5)
      block.call("/synthetic-home", { "identity_id" => request.portable_home_id }, commit_sha || "a" * 40, branch.presence || "main")
    end
    Agents::GithubImportSource.stub(:new, source) do
      Agents::Volume.stub(:new, ->(*) { flunk "must not seed a home on the house" }) do
        assert_no_difference "Agent.count" do
          GithubResidentImportJob.perform_now(request.id)
        end
      end
    end
    request.reload
    assert_equal "failed", request.status
    expected = Agents::VmBirthPolicy.current.refusal(kind: :import)
    assert expected, "this test house can't admit a VM (no procurement), so the import is refused with that reason"
    assert_equal expected, request.last_error
    assert_nil request.agent
  end

  test "a request queued before its account started paying makes no unpaid resident" do
    request = import_request
    approve_fixture(request)
    request.account.update!(billing_required: true)
    Agents::GithubImportSource.stub(:new, ->(*) { flunk "must not fetch" }) do
      assert_no_difference "Agent.count" do
        GithubResidentImportJob.perform_now(request.id)
      end
    end
    request.reload
    assert_equal "failed", request.status
    assert_equal Billing::BirthGate::IMPORT_NOT_OPEN, request.last_error
    assert_nil request.agent
  end

  test "an account that starts paying during the checkout makes no unpaid resident" do
    request = import_request
    approve_fixture(request)
    source = Object.new
    source.define_singleton_method(:with_checkout) do |branch:, commit_sha: nil, &block|
      request.account.update!(billing_required: true)
      block.call("/synthetic-home", { "identity_id" => request.portable_home_id }, commit_sha || "a" * 40, branch.presence || "main")
    end
    Agents::GithubImportSource.stub(:new, source) do
      Agents::Volume.stub(:new, ->(*) { flunk "must not seed a home" }) do
        assert_no_difference "Agent.count" do
          GithubResidentImportJob.perform_now(request.id)
        end
      end
    end
    assert_equal "failed", request.reload.status
    assert_nil request.agent
  end

  test "a resident already imported is retried even once its account pays" do
    request = import_request
    approve_fixture(request)
    volume = Object.new
    volume.define_singleton_method(:seed_from_directory!) { |_| }
    sandbox = Object.new
    sandbox.define_singleton_method(:spawn!) { }
    sandbox.define_singleton_method(:recreate!) { }
    sandbox.define_singleton_method(:active_turn?) { false }
    sandbox.define_singleton_method(:imported_runtime_trusted?) { true }
    run = lambda do
      Agents::GithubImportSource.stub(:new, source_stub(request)) do
        Agents::Volume.stub(:new, volume) do
          Agents::Sandbox.stub(:new, sandbox) { GithubResidentImportJob.perform_now(request.id) }
        end
      end
    end
    run.call
    assert_equal "ready", request.reload.status
    request.account.update!(billing_required: true)
    request.update!(status: "approved")
    run.call
    assert_equal "ready", request.reload.status
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
    assert_enqueued_with(job: GithubResidentImportJob, args: [ request.id ]) { request.retry_activation!(users(:user_1)) }
    assert_equal "approved", request.status
    sandbox.define_singleton_method(:imported_runtime_trusted?) { true }
    sandbox.define_singleton_method(:spawn!) { calls << :spawn }
    Agents::GithubImportSource.stub(:new, source_stub(request)) do
      Agents::Volume.stub(:new, volume) do
        Agents::Config.stub(:default_image, "helixkit-agent-runtime:new-deployment") do
          Agents::Sandbox.stub(:new, ->(agent) {
            assert_equal "helixkit-agent-runtime:new-deployment", agent.container_image
            sandbox
          }) { GithubResidentImportJob.perform_now(request.id) }
        end
      end
    end
    assert_equal [ :seed, :spawn ], calls
    assert_equal "ready", request.reload.status
    assert_not_equal request.approved_image, request.agent.container_image
    assert_nil request.approval_error
  end

  # A first import of the home, left waiting for runtime trust, as Reed's was
  # (JroAMY, 23 Nov).
  def import_until_trust(request)
    volume = Object.new
    volume.define_singleton_method(:seed_from_directory!) { |_| }
    sandbox = Object.new
    sandbox.define_singleton_method(:imported_runtime_trusted?) { false }
    Agents::GithubImportSource.stub(:new, source_stub(request)) do
      Agents::Volume.stub(:new, volume) do
        Agents::Sandbox.stub(:new, sandbox) { GithubResidentImportJob.perform_now(request.id) }
      end
    end
    assert_equal "needs_runtime_trust", request.reload.status
    request.agent
  end

  test "a second import of a home another resident holds fails with a sentence and is never left provisioning" do
    first = import_request
    second = import_request(connection: first.service_connection, name: "Second try")
    approve_fixture(first)
    holder = import_until_trust(first)
    approve_fixture(second)
    Agents::GithubImportSource.stub(:new, ->(*) { flunk "refused before the repository is fetched" }) do
      assert_no_difference "Agent.count" do
        GithubResidentImportJob.perform_now(second.id)
      end
    end
    second.reload
    assert_equal "failed", second.status
    assert_equal second.home_holder_error, second.last_error
    assert_equal "This home is already linked to #{holder.name}. To continue with that resident, open the original import request.", second.last_error
    assert_nil second.agent
    assert_equal "needs_runtime_trust", first.reload.status, "the resident that holds the home is untouched"
  end

  test "a home taken while the repository is fetched is refused before a home is made" do
    first = import_request
    second = import_request(connection: first.service_connection, name: "Second try")
    approve_fixture(first)
    approve_fixture(second)
    source = Object.new
    source.define_singleton_method(:with_checkout) do |branch:, commit_sha: nil, &block|
      # The first import makes its resident while this one is fetching.
      first.account.agents.new(github_resident_import_id: first.id, name: first.name, model_id: first.model_id,
        home_profile: "portable_v1", portable_home_id: first.portable_home_id,
        runtime: "offline", active: false, paused: true).save!(validate: false)
      block.call("/synthetic-home", { "identity_id" => second.portable_home_id }, commit_sha || "a" * 40, branch.presence || "main")
    end
    Agents::GithubImportSource.stub(:new, source) do
      GithubResidentImportJob.perform_now(second.id)
    end
    second.reload
    assert_equal "failed", second.status
    assert_includes second.last_error, "already linked to"
    assert_nil second.agent
  end

  test "the failure rescue marks the request failed even when the resident it built can't be saved" do
    first = import_request
    second = import_request(connection: first.service_connection, name: "Second try")
    approve_fixture(first)
    import_until_trust(first)
    approve_fixture(second)
    # The holder appears between the check and the save (a race the check
    # can't close): the unique home makes saving the new resident fail.
    second = GithubResidentImport.find(second.id)
    second.define_singleton_method(:home_holder_error) { nil }
    GithubResidentImport.stub(:find, second) do
      Agents::GithubImportSource.stub(:new, source_stub(second)) do
        Agents::Volume.stub(:new, ->(*) { flunk "no home is seeded" }) do
          assert_raises(ActiveRecord::RecordInvalid) { GithubResidentImportJob.perform_now(second.id) }
        end
      end
    end
    fresh = GithubResidentImport.find_by(id: second.id)
    assert_equal "failed", fresh.status, "never left provisioning with no message"
    assert_match(/Import or runtime setup failed/, fresh.last_error)
    assert_nil fresh.agent
  end

  test "a home held in another account fails like any setup failure and confirms nothing" do
    first = import_request
    second = import_request(connection: first.service_connection, name: "Second try")
    approve_fixture(second)
    accounts(:team_account).agents.new(name: "Elsewhere", model_id: first.model_id, home_profile: "portable_v1",
      portable_home_id: first.portable_home_id, runtime: "offline", active: false, paused: true).save!(validate: false)
    Agents::GithubImportSource.stub(:new, ->(*) { flunk "refused before the repository is fetched" }) do
      assert_no_difference "Agent.count" do
        GithubResidentImportJob.perform_now(second.id)
      end
    end
    second.reload
    assert_equal "failed", second.status
    assert_equal GithubResidentImportJob::FAILURE_MESSAGE, second.last_error
    assert_nil second.agent
  end

end
