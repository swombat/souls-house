source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.0"
# Use pg as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 6.6.0"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue", "~> 1.6.0"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", "~> 2.12.0", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"

# Use Amazon S3 for Active Storage in production
gem "aws-sdk-s3", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false

  # For testing email sending
  gem "letter_opener"

  # For testing external API calls
  gem "vcr"
  gem "webmock"
  # Ruby 4 removed CGI.parse from core; vcr 6.3 still calls it
  gem "cgi"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
  gem "chrome_devtools_rails"
end

group :test do
  # Rails 8.1's test runner does not yet discover tests under Minitest 6.
  gem "minitest", "~> 5.27"

  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
end

gem "inertia_rails", "~> 3.9"

gem "vite_rails", "~> 3.0"

gem "bcrypt", "~> 3.1"

gem "js-routes", "~> 2.4"

gem "hashids"

gem "ruby-openai"

# Ruby LLM - pin stable releases so provider and instrumentation behaviour is reproducible.
gem "ruby_llm", "~> 1.16.0"

gem "pagy", "~> 9.3"

gem "active_storage_validations"

gem "redcarpet"

gem "honeybadger", "~> 6.1"

# Soft delete support
gem "discard", "~> 1.3"

# X/Twitter API client
gem "x"
