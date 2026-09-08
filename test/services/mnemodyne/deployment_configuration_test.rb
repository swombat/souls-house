require "test_helper"
require "kamal"

class Mnemodyne::DeploymentConfigurationTest < ActiveSupport::TestCase

  # config/deploy.yml is now a template over this installation's identity
  # (docs/2026-09-07-forkable-house-plan-from-lume.md): rendering it requires
  # HOUSE_* env, normally supplied by config/house.env. These tests render
  # config/deploy.yml directly, bypassing bin/kamal's loading of that file,
  # so they set upstream's own values on ENV themselves rather than relying
  # on a house.env being present on the machine running the suite.
  UPSTREAM_HOUSE_ENV = {
    "HOUSE_DOMAIN" => "souls.house",
    "HOUSE_HOST" => "95.217.118.47",
    "HOUSE_SSH_USER" => "swombat",
    "HOUSE_SSH_PORT" => "12222",
    "HOUSE_IMAGE" => "dtenner/souls-house",
    "HOUSE_REGISTRY_USER" => "dtenner",
    "HOUSE_EMBEDDINGS_IMAGE" => "dtenner/souls-house-mnemodyne-embeddings",
    "HOUSE_AGENT_IMAGE" => "helixkit-agent-runtime:latest",
    "HOUSE_STORAGE" => "s3",
    "HOUSE_SITE_NAME" => "souls.house",
    "HOUSE_TRANSITION_ALIASES" => "helix-kit-web"
  }.freeze

  test "deployment validates with synthetic secrets and private inference wiring" do
    # Never evaluate .kamal/secrets or read actual deployment credentials.
    secrets = Hash.new("synthetic-secret-not-for-deployment")
    Kamal::Secrets.stub(:new, secrets) do
      with_house_env do
        raw = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/deploy.yml"))).result_with_hash({})).symbolize_keys
        config = Kamal::Configuration.new(raw, version: "synthetic-review")
        accessory = config.accessories.find { |item| item.name == "embeddings" }
        assert accessory
        assert_equal "souls-house-embeddings", accessory.service_name
        assert_equal "http://souls-house-embeddings:8080/v1/embeddings",
          raw.dig(:env, "clear", "MNEMODYNE_EMBEDDING_URL")
        assert_includes raw.dig(:env, "secret"), "MNEMODYNE_EMBEDDING_TOKEN"
        embedding = raw.dig(:accessories, "embeddings")
        assert_includes embedding.dig("env", "secret"), "MNEMODYNE_EMBEDDING_TOKEN"
        assert_nil embedding["port"]
        assert_equal true, embedding.dig("options", "read-only")
        assert_equal "512m", embedding.dig("options", "memory")
        assert_match(/@sha256:[0-9a-f]{64}\z/, embedding["image"])
      end
    end
  end

  setup do
    @previous_digest = ENV["MNEMODYNE_EMBEDDING_IMAGE_DIGEST"]
    ENV["MNEMODYNE_EMBEDDING_IMAGE_DIGEST"] = "sha256:#{"0" * 64}"
  end

  test "missing or malformed digest gives the actionable release instruction" do
    with_house_env do
      [ nil, "latest" ].each do |digest|
        ENV["MNEMODYNE_EMBEDDING_IMAGE_DIGEST"] = digest
        error = assert_raises(RuntimeError) do
          ERB.new(File.read(Rails.root.join("config/deploy.yml"))).result_with_hash({})
        end
        assert_includes error.message, "Set MNEMODYNE_EMBEDDING_IMAGE_DIGEST"
        assert_includes error.message, "sha256:"
      end
    end
  end

  teardown { ENV["MNEMODYNE_EMBEDDING_IMAGE_DIGEST"] = @previous_digest }

  private

  def with_house_env
    previous = UPSTREAM_HOUSE_ENV.keys.index_with { |key| ENV[key] }
    UPSTREAM_HOUSE_ENV.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

end
