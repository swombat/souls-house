require "test_helper"

module Agents
  class HostedProvisioningTest < ActiveSupport::TestCase

    setup do
      @user = users(:existing_user)
      @agent = agents(:research_assistant)
      @agent.update!(runtime: "provisioning", outbound_api_key: nil, outbound_api_token: nil,
        restic_password: nil, container_name: nil, endpoint_url: nil)
    end

    def place_on_vm!
      AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "pending")
    end

    # Any Docker-side check reaching a VM resident is a bug: it would refuse it
    # (as it did in the 2026-10-08 pilot) or, worse, touch local Docker.
    def without_local_docker(&block)
      Agents::Resources.stub(:new, ->(*) { raise "local Docker resources touched for a VM resident" }, &block)
    end

    def with_env(values)
      previous = values.keys.to_h { |key| [ key, ENV[key] ] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| ENV[key] = value }
    end

    test "a VM-placed resident gets its credentials without any local Docker step" do
      place_on_vm!
      without_local_docker do
        with_env("SOULSHOUSE_SANDBOX_HOST" => nil) do
          HostedProvisioning.new(agent: @agent, user: @user).prepare!(started_at: Time.current)
        end
      end

      @agent.reload
      assert @agent.outbound_api_key.present?
      assert @agent.outbound_api_token.present?
      assert_match(/\Atr_[0-9a-f]{48}\z/, @agent.trigger_bearer_token)
      assert_match(/\A[0-9a-f]{64}\z/, @agent.restic_password)
      assert_equal "hk-agent-#{@agent.uuid}", @agent.container_name
      assert_nil @agent.sandbox_host
      assert_nil @agent.endpoint_url
      assert_equal Agents::Config.default_image, @agent.container_image
      assert @agent.provisioning?
      assert_equal @agent.id, ApiKey.find(@agent.outbound_api_key_id).agent_id
    end

    test "preparing a VM resident again replaces its key but keeps its restic password" do
      place_on_vm!
      provisioning = HostedProvisioning.new(agent: @agent, user: @user)
      without_local_docker { provisioning.prepare!(started_at: Time.current) }
      first_key_id = @agent.reload.outbound_api_key_id
      first_token = @agent.outbound_api_token
      password = @agent.restic_password

      without_local_docker { provisioning.prepare!(started_at: Time.current) }

      @agent.reload
      assert_not_equal first_key_id, @agent.outbound_api_key_id
      assert_not_equal first_token, @agent.outbound_api_token
      assert_not ApiKey.exists?(first_key_id)
      assert_equal password, @agent.restic_password, "a new password would strand the resident's backups"
    end

    test "a local resident still goes through the local Resources check" do
      error = assert_raises(RuntimeError) do
        without_local_docker do
          with_env("SOULSHOUSE_SANDBOX_HOST" => "test-host") do
            HostedProvisioning.new(agent: @agent, user: @user).prepare!(started_at: Time.current)
          end
        end
      end
      assert_equal "local Docker resources touched for a VM resident", error.message
    end

    test "a resident that is not provisioning is refused either way" do
      place_on_vm!
      @agent.update!(runtime: "external")
      assert_raises(HostedProvisioning::ConfigurationError) do
        HostedProvisioning.new(agent: @agent, user: @user).prepare!(started_at: Time.current)
      end
    end

  end
end
