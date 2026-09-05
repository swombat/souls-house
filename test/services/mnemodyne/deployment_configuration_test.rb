require "test_helper"
require "kamal"

class Mnemodyne::DeploymentConfigurationTest < ActiveSupport::TestCase

  test "deployment validates with synthetic secrets and private inference wiring" do
    # Never evaluate .kamal/secrets or read actual deployment credentials.
    secrets = Hash.new("synthetic-secret-not-for-deployment")
    Kamal::Secrets.stub(:new, secrets) do
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

  setup do
    @previous_digest = ENV["MNEMODYNE_EMBEDDING_IMAGE_DIGEST"]
    ENV["MNEMODYNE_EMBEDDING_IMAGE_DIGEST"] = "sha256:#{"0" * 64}"
  end

  teardown { ENV["MNEMODYNE_EMBEDDING_IMAGE_DIGEST"] = @previous_digest }

end
