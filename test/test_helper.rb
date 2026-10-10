ENV["RAILS_ENV"] ||= "test"

module Warning

  class << self

    unless method_defined?(:helix_original_warn)
      alias_method :helix_original_warn, :warn
    end

    def warn(message, category: nil)
      return if message.include?("gems/marcel-1.1.0/lib/marcel/magic.rb:120: warning: literal string will be frozen")
      return if message.include?("gems/ruby-openai-") && message.include?("warning: ::Ruby is reserved for Ruby 3.5")

      if category
        helix_original_warn(message, category: category)
      else
        helix_original_warn(message)
      end
    end

  end

end

require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

module ActiveSupport
  class TestCase

    # Include ActiveJob test helpers for testing enqueued jobs
    include ActiveJob::TestHelper

    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...

    # Configure Active Storage URL options for tests
    setup do
      ActiveStorage::Current.url_options = { host: "test.host" }
      ensure_profiles_exist
    end

    private

    # Ensure that all fixture users have profiles
    # since fixtures don't trigger callbacks
    def ensure_profiles_exist
      User.find_each do |user|
        next if user.profile.present?

        # Create profile with some test data based on user email
        profile_data = case user.email_address
        when "test@example.com"
          { first_name: "Test", last_name: "User" }
        when "existing@example.com"
          { first_name: "Existing", last_name: "User" }
        when "admin@example.com"
          { first_name: "Admin", last_name: "User" }
        when "regular@example.com"
          { first_name: "Regular", last_name: "User" }
        when "confirmed@example.com"
          { first_name: "Confirmed", last_name: "User" }
        when "teamowner@example.com"
          { first_name: "Team", last_name: "Owner" }
        when "teamadmin@example.com"
          { first_name: "Team", last_name: "Admin" }
        when "teammember@example.com"
          { first_name: "Team", last_name: "Member" }
        when "othermember@example.com"
          { first_name: "Other", last_name: "Member" }
        else
          { first_name: "Test", last_name: "User" }
        end

        user.build_profile(profile_data.merge(theme: "system")).save!
      end
    end

  end
end

module InertiaTestHelpers

  def inertia_props
    return @inertia_props if @inertia_props

    if @response.media_type == "application/json"
      # JSON response (when X-Inertia header is present)
      @inertia_props = JSON.parse(@response.body)
    else
      # HTML response - extract from data-page attribute
      doc = Nokogiri::HTML(@response.body)
      data_page = doc.at_css("#app")&.attr("data-page")
      @inertia_props = data_page ? JSON.parse(data_page) : {}
    end
  end

  def inertia_component
    inertia_props["component"]
  end

  def inertia_shared_props
    inertia_props["props"] || {}
  end

end

class ActionDispatch::IntegrationTest

  include InertiaTestHelpers

  # Authentication helper for tests
  def sign_in(user)
    post "/login", params: {
      email_address: user.email_address,
      password: "password123"  # Fixture users use this password
    }
  end

end

require "support/vcr_setup"
