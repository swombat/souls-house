require "test_helper"

# Phase 1 of the forkable-house plan (docs/2026-09-07-forkable-house-plan-from-lume.md):
# the values that name *this* installation come from SOULSHOUSE_* env vars,
# defaulting to today's upstream behaviour when unset.
class IdentityEnvTest < ActiveSupport::TestCase

  test "Setting.instance default site name honours SOULSHOUSE_SITE_NAME" do
    Setting.destroy_all
    with_env("SOULSHOUSE_SITE_NAME" => "Fork House") do
      assert_equal "Fork House", Setting.instance.site_name
    end
  ensure
    Setting.destroy_all
  end

  test "Setting.instance default site name falls back to souls.house" do
    Setting.destroy_all
    with_env("SOULSHOUSE_SITE_NAME" => nil) do
      assert_equal "souls.house", Setting.instance.site_name
    end
  ensure
    Setting.destroy_all
  end

  test "ApplicationMailer default from honours SOULSHOUSE_MAIL_FROM" do
    with_env("SOULSHOUSE_MAIL_FROM" => "Fork House <hello@fork.example>") do
      reload_application_mailer
      assert_equal "Fork House <hello@fork.example>", ApplicationMailer.default[:from]
    end
  ensure
    reload_application_mailer
  end

  test "ApplicationMailer default from falls back to souls.house" do
    with_env("SOULSHOUSE_MAIL_FROM" => nil) do
      reload_application_mailer
      assert_equal "souls.house <hello@souls.house>", ApplicationMailer.default[:from]
    end
  ensure
    reload_application_mailer
  end

  test "public_url prefers SOULSHOUSE_PUBLIC_URL over credentials" do
    with_env("SOULSHOUSE_PUBLIC_URL" => "https://fork.example") do
      reload_house_initializer
      assert_equal "https://fork.example", Rails.configuration.x.public_url
    end
  ensure
    reload_house_initializer
  end

  test "public_url falls back to credentials.app.url when env is absent" do
    with_env("SOULSHOUSE_PUBLIC_URL" => nil) do
      reload_house_initializer
      assert_equal Rails.application.credentials.dig(:app, :url), Rails.configuration.x.public_url
    end
  ensure
    reload_house_initializer
  end

  private

  # `default from:` and the house initializer both read ENV once, at load
  # time, by design (matches production's own boot-time evaluation). To
  # observe a different ENV value in a test we re-`load` the file under a
  # stubbed ENV, then restore it — the same file is not `require`d elsewhere
  # mid-process, so this only ever affects this process's test run.
  def reload_application_mailer
    load Rails.root.join("app/mailers/application_mailer.rb")
  end

  def reload_house_initializer
    load Rails.root.join("config/initializers/house.rb")
  end

  def with_env(overrides)
    previous = overrides.keys.index_with { |key| ENV[key] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

end
