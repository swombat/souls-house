require "test_helper"
require Rails.root.join("config/house")

# Phase 1 of the forkable-house plan (docs/2026-09-07-forkable-house-plan-from-lume.md):
# config/deploy.yml is an ERB template over HOUSE_* env, and nothing else in
# the repository should name a specific installation.
class DeployTemplateTest < ActiveSupport::TestCase

  UPSTREAM_IDENTIFIERS = %w[
    dtenner
    95.217.118.47
    swombat
    souls.house
    12222
    988
    ssh://misc
    helix-kit-web
  ].freeze

  DUMMY_DIGEST = "sha256:#{"0" * 64}".freeze

  test "rendering with only house.env.example (plus a digest) succeeds and names no upstream identifier" do
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST)) do
      rendered = render_deploy_yml

      UPSTREAM_IDENTIFIERS.each do |identifier|
        assert_not_includes rendered, identifier, "expected the example-rendered deploy.yml not to mention #{identifier}"
      end

      assert YAML.safe_load(rendered).present?
    end
  end

  test "rendering without house.env raises, pointing at house.env" do
    with_env(example_env.except("HOUSE_DOMAIN", "HOUSE_HOST")) do
      error = assert_raises(RuntimeError) { render_deploy_yml }
      assert_includes error.message, "house.env"
    end
  end

  test "deployment wires the fork domain into mailer links as well as public callbacks" do
    with_env(example_env.merge("HOUSE_DOMAIN" => "my-house.example", "HOUSE_EMBEDDINGS_DIGEST" => DUMMY_DIGEST)) do
      runtime = YAML.safe_load(render_deploy_yml).fetch("env").fetch("clear")
      assert_equal "https://my-house.example", runtime.fetch("SOULSHOUSE_PUBLIC_URL")
      assert_equal "my-house.example", runtime.fetch("SOULSHOUSE_DOMAIN")
      options = { host: runtime.fetch("SOULSHOUSE_DOMAIN") }
      assert_equal "my-house.example", URI(Rails.application.routes.url_helpers.email_confirmation_url(token: "test", **options)).host
      assert_equal "my-house.example", URI(Rails.application.routes.url_helpers.edit_password_url("test", **options)).host
    end
  end

  test "rendering with a malformed embeddings digest raises" do
    with_env(example_env.merge("HOUSE_EMBEDDINGS_DIGEST" => "latest")) do
      error = assert_raises(RuntimeError) { render_deploy_yml }
      assert_includes error.message, "HOUSE_EMBEDDINGS_DIGEST"
      assert_includes error.message, "sha256:"
    end
  end

  test "House.parse handles comments, blank lines, and quotes" do
    text = <<~ENV
      # a comment
      HOUSE_DOMAIN=house.example.org

      HOUSE_SITE_NAME="Quoted House"
      HOUSE_MAIL_FROM='Single Quoted <hello@house.example.org>'
      HOUSE_TRANSITION_ALIASES=
    ENV

    parsed = House.parse(text)

    assert_equal({
      "HOUSE_DOMAIN" => "house.example.org",
      "HOUSE_SITE_NAME" => "Quoted House",
      "HOUSE_MAIL_FROM" => "Single Quoted <hello@house.example.org>",
      "HOUSE_TRANSITION_ALIASES" => ""
    }, parsed)
  end

  test ".kamal/secrets resolves every secret through bin/house, never $(cat ...)" do
    secrets = File.read(Rails.root.join(".kamal/secrets"))
    assert_not_includes secrets, "$(cat "
  end

  private

  def render_deploy_yml
    ERB.new(File.read(Rails.root.join("config/deploy.yml")), trim_mode: "-").result
  end

  def example_env
    House.parse(File.read(Rails.root.join("config/house.env.example")))
  end

  def with_env(overrides)
    keys = (overrides.keys + %w[HOUSE_DOMAIN HOUSE_HOST HOUSE_EMBEDDINGS_DIGEST MNEMODYNE_EMBEDDING_IMAGE_DIGEST]).uniq
    previous = keys.index_with { |key| ENV[key] }
    keys.each { |key| ENV.delete(key) }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

end
