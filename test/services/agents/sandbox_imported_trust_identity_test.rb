require "test_helper"

module Agents
  # Mira, jERNRJ (23 Nov 2026): the trust check mounted the identity volume
  # without looking for it, and an import retry with identity_seeded_at set
  # never reseeds, so a lost home would have come back empty.
  class SandboxImportedTrustIdentityTest < ActiveSupport::TestCase

    test "a missing identity volume is refused, not mounted" do
      agent = agents(:research_assistant)
      agent.update_columns(uuid: SecureRandom.uuid)
      agent.define_singleton_method(:github_resident_import) { Object.new }
      sandbox = Sandbox.new(agent)
      identity = Agents::Volume.new(agent).volume_name
      docker_runs = []
      sandbox.define_singleton_method(:verify_resources!) { true }
      sandbox.define_singleton_method(:volume_exists?) { |name| name != identity }
      sandbox.define_singleton_method(:docker_capture) { |*args| docker_runs << args; { ok: true, stdout: "" } }
      sandbox.define_singleton_method(:docker_system) { |*args, **| docker_runs << args; true }

      error = assert_raises(Sandbox::SandboxError) { sandbox.imported_runtime_trusted? }
      assert_equal "identity volume missing; not recreated", error.message
      assert_empty docker_runs
    end

  end
end
