require_relative "boot"

require "rails/all"

LocalInstance.current.configure!

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module SoulsHouse
  class Application < Rails::Application

    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    if LocalInstance.current.local?
      config.middleware.use LocalInstance::Middleware
      config.session_store :cookie_store, key: LocalInstance.current.cookie("_souls_house_session")
    end

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # Preserve the pre-1.5 Solid Queue behavior for schedules without a zone.
    config.solid_queue.time_zone = nil
    # config.eager_load_paths << Rails.root.join("extras")
    #
    ## Disable unnecessary files when generating
    config.generators do |g|
      g.helper false               # No helper files
      g.assets false               # No CSS/JS assets
      g.view_specs false           # No view tests
      g.helper_specs false         # No helper tests
      g.routing_specs false        # No routing tests
      g.test_framework nil         # No test framework
      g.fixture_replacement nil    # No fixtures
      g.template_engine nil        # No views/templates
    end

  end
end
